import XCTest
@testable import ExtensionAPI

private struct TestConfig: Sendable, Equatable {
    var value: String
}

private struct CounterState: Sendable, Equatable {
    var count: Int
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class ExtensionAPITests: XCTestCase {
    func testExtensionDataStoresTypedValuesByScope() {
        let data = ExtensionData(levelId: "thread-1")

        XCTAssertNil(data.get(CounterState.self))
        let initialized = data.getOrInit(CounterState.self) { CounterState(count: 1) }
        XCTAssertEqual(initialized, CounterState(count: 1))
        XCTAssertEqual(data.getOrInit(CounterState.self) { CounterState(count: 2) },
                       CounterState(count: 1))

        XCTAssertEqual(data.insert(CounterState(count: 3)), CounterState(count: 1))
        XCTAssertEqual(data.get(CounterState.self), CounterState(count: 3))
        XCTAssertEqual(data.remove(CounterState.self), CounterState(count: 3))
        XCTAssertNil(data.get(CounterState.self))
        XCTAssertEqual(data.levelId, "thread-1")
    }

    func testRegistryRunsLifecycleConfigAndTokenCallbacksInOrder() {
        let session = ExtensionData(levelId: "session")
        let thread = ExtensionData(levelId: "thread")
        let turn = ExtensionData(levelId: "turn")
        let recorder = EventRecorder()

        let builder = ExtensionRegistryBuilder<TestConfig>()
        builder.threadLifecycle(
            onStart: { input in recorder.append("thread-start:\(input.config.value)") },
            onResume: { input in recorder.append("thread-resume:\(input.threadId)") },
            onStop: { input in recorder.append("thread-stop:\(input.threadId)") })
        builder.turnLifecycle(
            onStart: { input in recorder.append("turn-start:\(input.turnId)") },
            onStop: { input in recorder.append("turn-stop:\(input.turnId)") },
            onAbort: { input in recorder.append("turn-abort:\(input.reason)") })
        builder.configContributor { input in
            recorder.append("config:\(input.previousConfig.value)->\(input.newConfig.value)")
        }
        builder.tokenUsageContributor { input in
            recorder.append("usage:\(input.usage.totalTokens)")
        }

        let registry = builder.build()
        registry.onThreadStart(ThreadStartInput(sessionStore: session, threadStore: thread,
                                                config: TestConfig(value: "a")))
        registry.onThreadResume(ThreadResumeInput(sessionStore: session, threadStore: thread,
                                                  threadId: "thread"))
        registry.onTurnStart(TurnStartInput(threadStore: thread, turnStore: turn,
                                            turnId: "turn"))
        registry.onConfigChanged(ConfigChangedInput(sessionStore: session, threadStore: thread,
                                                    previousConfig: TestConfig(value: "a"),
                                                    newConfig: TestConfig(value: "b")))
        registry.onTokenUsage(TokenUsageInput(sessionStore: session, threadStore: thread,
                                              turnStore: turn,
                                              usage: TokenUsageCheckpoint(inputTokens: 2,
                                                                          outputTokens: 3,
                                                                          totalTokens: 5)))
        registry.onTurnAbort(TurnAbortInput(threadStore: thread, turnStore: turn,
                                            turnId: "turn", reason: "deadline"))
        registry.onTurnStop(TurnStopInput(threadStore: thread, turnStore: turn,
                                          turnId: "turn"))
        registry.onThreadStop(ThreadStopInput(sessionStore: session, threadStore: thread,
                                              threadId: "thread"))

        XCTAssertEqual(recorder.events, [
            "thread-start:a",
            "thread-resume:thread",
            "turn-start:turn",
            "config:a->b",
            "usage:5",
            "turn-abort:deadline",
            "turn-stop:turn",
            "thread-stop:thread",
        ])
    }

    func testPromptAndApprovalContributorsAreOrderedAndFirstClaimWins() async {
        let session = ExtensionData(levelId: "session")
        let thread = ExtensionData(levelId: "thread")
        thread.insert(CounterState(count: 7))

        let builder = ExtensionRegistryBuilder<TestConfig>()
        builder.contextContributor { _, threadStore in
            let count = threadStore.get(CounterState.self)?.count ?? 0
            return [PromptFragment(slot: .developer, text: "dev-\(count)")]
        }
        builder.contextContributor { _, _ in
            [PromptFragment(slot: .contextualUser, text: "user")]
        }
        builder.approvalReviewContributor { _, _, prompt in
            prompt.contains("ignore") ? nil : .denied(message: "first")
        }
        builder.approvalReviewContributor { _, _, _ in
            .approved
        }

        let registry = builder.build()
        let fragments = await registry.promptFragments(sessionStore: session, threadStore: thread)
        XCTAssertEqual(fragments, [
            PromptFragment(slot: .developer, text: "dev-7"),
            PromptFragment(slot: .contextualUser, text: "user"),
        ])

        let claimed = await registry.approvalReview(sessionStore: session, threadStore: thread,
                                                    prompt: "please review")
        XCTAssertEqual(claimed, .denied(message: "first"))

        let fallback = await registry.approvalReview(sessionStore: session, threadStore: thread,
                                                     prompt: "ignore first")
        XCTAssertEqual(fallback, .approved)
    }
}
