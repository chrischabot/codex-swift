import XCTest
@testable import ModelClient
@testable import InfraPrimitives

final class ModelClientTests: XCTestCase {

    private func drain(_ s: ResponseStream) async throws -> [ResponseEvent] {
        var out: [ResponseEvent] = []
        for try await e in s.events { out.append(e) }
        return out
    }

    func testMockHelloScenarioAndCacheKeyCapture() async throws {
        let mock = MockModelClient([.hello("Hi")])
        let s = try await mock.stream(
            Prompt(instructions: "be nice", input: [.userText("hello")]),
            ModelSettings(model: "gpt-5.1-codex", threadId: "thr_42", turnState: "ts-abc"))
        let events = try await drain(s)
        XCTAssertEqual(events.first, .created)
        XCTAssertTrue(events.contains(.agentDelta(itemId: "msg_1", delta: "Hi")))
        XCTAssertEqual(events.last, .completed(responseId: "resp_1", totalTokens: 12, endTurn: true, usage: nil))

        let cap = await mock.capturedRequests()
        XCTAssertEqual(cap.count, 1)
        XCTAssertEqual(cap[0].promptCacheKey, "thr_42", "prompt_cache_key must equal threadId")
        XCTAssertEqual(cap[0].turnState, "ts-abc", "sticky turn-state must be forwarded")

        let (rid, _, tokens) = await s.lastResponse.snapshot()
        XCTAssertEqual(rid, "resp_1")
        XCTAssertEqual(tokens, 12)
    }

    func testStreamMapperDoesNotDropEventsUnderSlowConsumer() async throws {
        // Many events through a tiny-capacity mapper; blocking backpressure
        // must deliver ALL of them (including the terminal completion).
        let n = 500
        let s = StreamMapper.map(capacity: 2) {
            AsyncThrowingStream<ResponseEvent, any Error> { cont in
                let t = Task {
                    for i in 0..<n { cont.yield(.agentDelta(itemId: "x", delta: "\(i)")) }
                    cont.yield(.completed(responseId: "r", totalTokens: 1, endTurn: true, usage: nil))
                    cont.finish()
                }
                cont.onTermination = { _ in t.cancel() }
            }
        }
        var count = 0
        var sawCompleted = false
        for try await e in s.events {
            count += 1
            if case .completed = e { sawCompleted = true }
            try? await Task.sleep(for: .microseconds(50)) // slow consumer
        }
        XCTAssertEqual(count, n + 1, "no events dropped under backpressure")
        XCTAssertTrue(sawCompleted, "terminal completion must never be lost")
    }

    func testStreamMapperConsumerDropCancelsUpstream() async throws {
        let started = Counter2()
        let cancelled = Counter2()
        func makeStreamAndConsumeOne() async throws {
            let s = StreamMapper.map(capacity: 4) {
                AsyncThrowingStream<ResponseEvent, any Error> { cont in
                    let t = Task {
                        await started.inc()
                        var i = 0
                        while !Task.isCancelled {
                            cont.yield(.agentDelta(itemId: "x", delta: "\(i)"))
                            i += 1
                            try? await Task.sleep(for: .milliseconds(2))
                        }
                        await cancelled.inc()
                        cont.finish()
                    }
                    cont.onTermination = { _ in t.cancel() }
                }
            }
            var it = s.events.makeAsyncIterator()
            _ = try await it.next()
            // `s` and `it` go out of scope at the end of this function →
            // AsyncThrowingStream termination fires deterministically.
        }
        try await makeStreamAndConsumeOne()
        try await Task.sleep(for: .milliseconds(80))
        let startedValue = await started.value
        let cancelledValue = await cancelled.value
        XCTAssertEqual(startedValue, 1)
        XCTAssertGreaterThanOrEqual(cancelledValue, 1, "upstream must stop when consumer drops")
    }

    func testRetryingClientRetriesThenSucceeds() async throws {
        var lim = Limits(); lim.streamMaxRetries = 3
        lim.retryBaseDelay = .milliseconds(1); lim.retryMaxDelay = .milliseconds(2)
        let mock = MockModelClient([
            MockScenario([.failRetryable("transient 503")]),
            .hello("recovered"),
        ], limits: lim)
        let client = RetryingModelClient(base: mock, fallback: nil, limits: lim)
        let s = try await client.stream(Prompt(instructions: "", input: [.userText("go")]),
                                        ModelSettings(model: "m", threadId: "t"))
        let events = try await drain(s)
        XCTAssertTrue(events.contains(.agentDone(itemId: "msg_1", text: "recovered")))
        let captured = await mock.capturedRequests()
        XCTAssertEqual(captured.count, 2, "one failed attempt + one success")
    }

    func testRetryingClientHonorsRetryAfterBeforeRetry() async throws {
        var lim = Limits()
        lim.streamMaxRetries = 1
        lim.retryTokensCapacity = 1
        lim.retryTokensPerSecond = 0
        lim.retryBaseDelay = .milliseconds(1)
        lim.retryMaxDelay = .milliseconds(200)
        let retryAfter = Duration.milliseconds(80)
        let primary = RetryAfterOnceClient(retryAfter: retryAfter)
        let client = RetryingModelClient(base: primary, limits: lim)

        let start = MonotonicClock.now()
        let s = try await client.stream(Prompt(instructions: "", input: []),
                                        ModelSettings(model: "m", threadId: "t"))
        let events = try await drain(s)
        let elapsed = MonotonicClock.now() - start

        XCTAssertTrue(events.contains(.agentDone(itemId: "msg", text: "ok")))
        XCTAssertGreaterThanOrEqual(elapsed, retryAfter.seconds * 0.75,
                                    "Retry-After should delay the retry path")
        let callCount = await primary.calls()
        XCTAssertEqual(callCount, 2)
    }

    func testRetryBudgetExhaustionThrows() async {
        var lim = Limits(); lim.streamMaxRetries = 10
        lim.retryTokensCapacity = 2; lim.retryTokensPerSecond = 0
        lim.retryBaseDelay = .milliseconds(1); lim.retryMaxDelay = .milliseconds(1)
        let mock = MockModelClient(repeating: MockScenario([.failRetryable("always 503")]),
                                   times: 50, limits: lim)
        let client = RetryingModelClient(base: mock, fallback: nil, limits: lim)
        do {
            _ = try await client.stream(Prompt(instructions: "", input: []),
                                        ModelSettings(model: "m", threadId: "t"))
            XCTFail("expected exhaustion to throw")
        } catch let e as ModelError {
            XCTAssertTrue(e.retryable)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testFallbackEngagesOnceWhenBudgetExhausted() async throws {
        var lim = Limits(); lim.streamMaxRetries = 1
        lim.retryTokensCapacity = 1; lim.retryTokensPerSecond = 0
        lim.retryBaseDelay = .milliseconds(1); lim.retryMaxDelay = .milliseconds(1)
        let primary = MockModelClient(repeating: MockScenario([.failRetryable("ws down")]),
                                      times: 10, limits: lim)
        let fallback = MockModelClient([.hello("via http")], limits: lim)
        let client = RetryingModelClient(base: primary, fallback: fallback, limits: lim)
        let s = try await client.stream(Prompt(instructions: "", input: []),
                                        ModelSettings(model: "m", threadId: "t"))
        let events = try await drain(s)
        XCTAssertTrue(events.contains(.agentDone(itemId: "msg_1", text: "via http")))
        let engaged = await client.isFallbackEngaged()
        XCTAssertTrue(engaged)
    }

    func testTransportFallbackEngagesOnMidStreamFailureAndStaysSticky() async throws {
        var lim = Limits()
        lim.streamMaxRetries = 0
        lim.retryTokensCapacity = 0
        lim.retryTokensPerSecond = 0
        lim.retryBaseDelay = .milliseconds(1)
        lim.retryMaxDelay = .milliseconds(1)
        let primary = MidStreamFailureClient()
        let fallback = CountingSuccessClient(text: "via https")
        let client = TransportFallbackModelClient(primary: primary,
                                                  fallback: fallback,
                                                  limits: lim)

        let first = try await client.stream(
            Prompt(instructions: "", input: [.userText("go")]),
            ModelSettings(model: "m", threadId: "t"))
        let firstEvents = try await drain(first)
        XCTAssertTrue(firstEvents.contains(.created),
                      "the wrapper observes already-opened WS streams")
        XCTAssertTrue(firstEvents.contains(.agentDone(itemId: "msg", text: "via https")))
        let firstEngaged = await client.isFallbackEngaged()
        let firstPrimaryCalls = await primary.calls()
        let firstFallbackCalls = await fallback.calls()
        XCTAssertTrue(firstEngaged)
        XCTAssertEqual(firstPrimaryCalls, 2,
                       "Limits.clamped floors the retry budget at one retry")
        XCTAssertEqual(firstFallbackCalls, 1)

        let second = try await client.stream(
            Prompt(instructions: "", input: [.userText("again")]),
            ModelSettings(model: "m", threadId: "t"))
        let secondEvents = try await drain(second)
        XCTAssertTrue(secondEvents.contains(.agentDone(itemId: "msg", text: "via https")))
        let secondPrimaryCalls = await primary.calls()
        let secondFallbackCalls = await fallback.calls()
        XCTAssertEqual(secondPrimaryCalls, 2,
                       "fallback must remain session-sticky after WS is disabled")
        XCTAssertEqual(secondFallbackCalls, 2)
    }

    func testTransportFallbackRetriesMidStreamBeforeFallback() async throws {
        var lim = Limits()
        lim.streamMaxRetries = 1
        lim.retryTokensCapacity = 1
        lim.retryTokensPerSecond = 0
        lim.retryBaseDelay = .milliseconds(1)
        lim.retryMaxDelay = .milliseconds(1)
        let primary = FailOnceMidStreamThenSucceedClient()
        let fallback = CountingSuccessClient(text: "fallback")
        let client = TransportFallbackModelClient(primary: primary,
                                                  fallback: fallback,
                                                  limits: lim)

        let stream = try await client.stream(
            Prompt(instructions: "", input: [.userText("go")]),
            ModelSettings(model: "m", threadId: "t"))
        let events = try await drain(stream)

        XCTAssertTrue(events.contains(.agentDone(itemId: "msg", text: "primary recovered")))
        let engaged = await client.isFallbackEngaged()
        let primaryCalls = await primary.calls()
        let fallbackCalls = await fallback.calls()
        XCTAssertFalse(engaged)
        XCTAssertEqual(primaryCalls, 2)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testTransportFallbackTreatsUnderlyingCancellationAsRetryableTransportFailure() async throws {
        var lim = Limits()
        lim.streamMaxRetries = 0
        lim.retryTokensCapacity = 0
        lim.retryTokensPerSecond = 0
        lim.retryBaseDelay = .milliseconds(1)
        lim.retryMaxDelay = .milliseconds(1)
        let primary = UnderlyingCancellationClient()
        let fallback = CountingSuccessClient(text: "https after cancel")
        let client = TransportFallbackModelClient(primary: primary,
                                                  fallback: fallback,
                                                  limits: lim)

        let stream = try await client.stream(
            Prompt(instructions: "", input: [.userText("go")]),
            ModelSettings(model: "m", threadId: "t"))
        let events = try await drain(stream)

        XCTAssertTrue(events.contains(.agentDone(itemId: "msg",
                                                text: "https after cancel")))
        let engaged = await client.isFallbackEngaged()
        let primaryCalls = await primary.calls()
        let fallbackCalls = await fallback.calls()
        XCTAssertTrue(engaged,
                      "URLSession/WebSocket cancellation from the primary transport should engage HTTPS fallback")
        XCTAssertEqual(primaryCalls, 2,
                       "Limits.clamped floors the retry budget at one retry before fallback")
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testAuthRefreshingClientRetriesWithFreshTokenAfter401() async throws {
        let refresh = RefreshProbe(token: "NEW_TOKEN")
        let client = AuthRefreshingModelClient(
            initial: AlwaysUnauthorizedClient(),
            refreshToken: { await refresh.refresh() },
            makeClient: { TokenEchoClient(token: $0) })

        let s = try await client.stream(Prompt(instructions: "", input: []),
                                        ModelSettings(model: "m", threadId: "t"))
        let events = try await drain(s)

        XCTAssertTrue(events.contains(.agentDone(itemId: "msg", text: "NEW_TOKEN")))
        let refreshCount = await refresh.count()
        XCTAssertEqual(refreshCount, 1)
    }

    func testAuthRefreshingClientCoalescesConcurrent401Refreshes() async throws {
        let refresh = RefreshProbe(token: "COALESCED", delay: .milliseconds(80))
        let client = AuthRefreshingModelClient(
            initial: AlwaysUnauthorizedClient(),
            refreshToken: { await refresh.refresh() },
            makeClient: { TokenEchoClient(token: $0) })

        let results = try await withThrowingTaskGroup(of: [ResponseEvent].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let s = try await client.stream(Prompt(instructions: "", input: []),
                                                    ModelSettings(model: "m", threadId: UUID().uuidString))
                    var out: [ResponseEvent] = []
                    for try await e in s.events { out.append(e) }
                    return out
                }
            }
            var out: [[ResponseEvent]] = []
            for try await events in group { out.append(events) }
            return out
        }

        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy {
            $0.contains(.agentDone(itemId: "msg", text: "COALESCED"))
        })
        let refreshCount = await refresh.count()
        XCTAssertEqual(refreshCount, 1, "simultaneous 401s must collapse to one auth refresh")
    }
}

actor Counter2 { private(set) var value = 0; func inc() { value += 1 } }

private actor RetryAfterOnceClient: ModelClient {
    private let retryAfter: Duration
    private var callCount = 0

    init(retryAfter: Duration) {
        self.retryAfter = retryAfter
    }

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        callCount += 1
        if callCount == 1 {
            throw ModelError("rate limited",
                             retryable: true,
                             httpStatus: 429,
                             retryAfter: retryAfter)
        }
        return ResponseStream(
            events: AsyncThrowingStream<ResponseEvent, any Error> { cont in
                cont.yield(.created)
                cont.yield(.agentDone(itemId: "msg", text: "ok"))
                cont.yield(.completed(responseId: "resp", totalTokens: 1,
                                      endTurn: true))
                cont.finish()
            },
            lastResponse: LastResponseBox())
    }

    func calls() -> Int { callCount }
}

private actor MidStreamFailureClient: ModelClient {
    private var callCount = 0

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        callCount += 1
        return ResponseStream(
            events: AsyncThrowingStream<ResponseEvent, any Error> { cont in
                cont.yield(.created)
                cont.finish(throwing: ModelError("websocket dropped",
                                                 retryable: true))
            },
            lastResponse: LastResponseBox())
    }

    func calls() -> Int { callCount }
}

private actor FailOnceMidStreamThenSucceedClient: ModelClient {
    private var callCount = 0

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        callCount += 1
        let attempt = callCount
        return ResponseStream(
            events: AsyncThrowingStream<ResponseEvent, any Error> { cont in
                cont.yield(.created)
                if attempt == 1 {
                    cont.finish(throwing: ModelError("first websocket dropped",
                                                     retryable: true))
                    return
                }
                cont.yield(.agentDone(itemId: "msg", text: "primary recovered"))
                cont.yield(.completed(responseId: "resp-primary", totalTokens: 2,
                                      endTurn: true))
                cont.finish()
            },
            lastResponse: LastResponseBox())
    }

    func calls() -> Int { callCount }
}

private actor UnderlyingCancellationClient: ModelClient {
    private var callCount = 0

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        callCount += 1
        return ResponseStream(
            events: AsyncThrowingStream<ResponseEvent, any Error> { cont in
                cont.finish(throwing: CancellationError())
            },
            lastResponse: LastResponseBox())
    }

    func calls() -> Int { callCount }
}

private actor CountingSuccessClient: ModelClient {
    private let text: String
    private var callCount = 0

    init(text: String) {
        self.text = text
    }

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        callCount += 1
        let text = self.text
        return ResponseStream(
            events: AsyncThrowingStream<ResponseEvent, any Error> { cont in
                cont.yield(.created)
                cont.yield(.agentDone(itemId: "msg", text: text))
                cont.yield(.completed(responseId: "resp-fallback", totalTokens: 1,
                                      endTurn: true))
                cont.finish()
            },
            lastResponse: LastResponseBox())
    }

    func calls() -> Int { callCount }
}

private actor AlwaysUnauthorizedClient: ModelClient {
    private(set) var callCount = 0

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        callCount += 1
        throw ModelError("unauthorized", retryable: false, httpStatus: 401)
    }
}

private struct TokenEchoClient: ModelClient {
    let token: String

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        ResponseStream(
            events: AsyncThrowingStream<ResponseEvent, any Error> { cont in
                cont.yield(.created)
                cont.yield(.agentDone(itemId: "msg", text: token))
                cont.yield(.completed(responseId: "resp", totalTokens: 1,
                                      endTurn: true))
                cont.finish()
            },
            lastResponse: LastResponseBox())
    }
}

private actor RefreshProbe {
    private let token: String?
    private let delay: Duration
    private var refreshes = 0

    init(token: String?, delay: Duration = .zero) {
        self.token = token
        self.delay = delay
    }

    func refresh() async -> String? {
        refreshes += 1
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return token
    }

    func count() -> Int { refreshes }
}
