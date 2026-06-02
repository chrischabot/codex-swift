import XCTest
import Foundation
@testable import Supervisor
@testable import ModelClient
@testable import WireProtocol

/// Exercises the live realtime voice bridge (`LiveRealtimeBackend` /
/// `LiveRealtimeSession`) end-to-end without a socket: a fake `RealtimeChannel`
/// records the client events the session sends and lets the test inject server
/// events. Verifies the exact `thread/realtime/*` notification shapes the web
/// connector decodes (`connector-codex.ts`).
final class RealtimeBridgeTests: XCTestCase {

    // MARK: Fakes

    /// Records sent client events; yields injected server events on demand.
    /// All state is guarded by a synchronous `locked` helper — `NSLock` cannot
    /// be locked directly from the `async` protocol methods under Swift 6.
    final class FakeRealtimeChannel: RealtimeChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var sentEvents: [RealtimeClientEvent] = []
        private var continuation: AsyncThrowingStream<RealtimeServerEvent, any Error>.Continuation?
        private var closeCount = 0

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }

        func open() async throws -> AsyncThrowingStream<RealtimeServerEvent, any Error> {
            let (stream, cont) = AsyncThrowingStream.makeStream(of: RealtimeServerEvent.self)
            locked { continuation = cont }
            return stream
        }

        func send(_ event: RealtimeClientEvent) async throws {
            locked { sentEvents.append(event) }
        }

        func close() async {
            let cont = locked { () -> AsyncThrowingStream<RealtimeServerEvent, any Error>.Continuation? in
                closeCount += 1
                let c = continuation
                continuation = nil
                return c
            }
            cont?.finish()
        }

        func push(_ event: RealtimeServerEvent) {
            locked { continuation }?.yield(event)
        }

        var sent: [RealtimeClientEvent] { locked { sentEvents } }
        var closes: Int { locked { closeCount } }
    }

    /// Thread-safe collector for the `(method, params)` notifications the
    /// session emits.
    final class EmitCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, JSONValue)] = []
        func record(_ method: String, _ params: JSONValue) {
            lock.lock(); items.append((method, params)); lock.unlock()
        }
        var all: [(String, JSONValue)] { lock.lock(); defer { lock.unlock() }; return items }
        var methods: [String] { all.map(\.0) }
        func params(for method: String) -> JSONValue? { all.first { $0.0 == method }?.1 }
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func startSession(_ channel: FakeRealtimeChannel,
                              collector: EmitCollector,
                              modality: String = "audio",
                              voice: String? = "marin",
                              instructions: String? = "Be nice")
        async throws -> any RealtimeBackendSession {
        let factory = LiveRealtimeBackend(channelFactory: { _ in channel }).makeFactory()
        let params = RealtimeStartParams(threadId: "th_voice", outputModality: modality,
                                         voice: voice, instructions: instructions)
        return try await factory(params) { method, paramsValue in
            collector.record(method, paramsValue)
        }
    }

    // MARK: Tests

    func testSessionUpdateAppliedOnStart() async throws {
        let channel = FakeRealtimeChannel()
        let collector = EmitCollector()
        let session = try await startSession(channel, collector: collector)
        await waitUntil { channel.sent.contains { if case .sessionUpdate = $0 { return true }; return false } }
        guard let update = channel.sent.first(where: { if case .sessionUpdate = $0 { return true }; return false }),
              case let .sessionUpdate(config) = update else {
            return XCTFail("session.update not sent")
        }
        XCTAssertEqual(config.instructions, "Be nice")
        XCTAssertEqual(config.voice, "marin")
        XCTAssertEqual(config.modalities, ["audio", "text"])
        withExtendedLifetime(session) {}
    }

    func testTranslatesAssistantTranscriptAndAudio() async throws {
        let channel = FakeRealtimeChannel()
        let collector = EmitCollector()
        // Hold the session like the RequestRouter does (it stores live sessions
        // in `liveRealtimeSessions`); the pump uses `[weak self]`, so a dropped
        // session stops streaming.
        let session = try await startSession(channel, collector: collector)
        channel.push(.responseTranscriptDelta(itemId: "a", delta: "Hi"))
        channel.push(.responseAudioDelta(itemId: "a", base64: "QQ=="))
        channel.push(.responseTranscriptDone(itemId: "a", transcript: "Hi there"))

        await waitUntil {
            collector.methods.filter { $0.hasPrefix("thread/realtime/") }.count >= 3
        }
        XCTAssertTrue(collector.methods.contains("thread/realtime/transcript/delta"))
        XCTAssertTrue(collector.methods.contains("thread/realtime/outputAudio/delta"))
        XCTAssertTrue(collector.methods.contains("thread/realtime/transcript/done"))

        // Audio param shape must match what useRealtimeVoice.playAudio decodes.
        let audio = collector.params(for: "thread/realtime/outputAudio/delta")?["audio"]?.objectValue
        XCTAssertEqual(audio?["data"]?.stringValue, "QQ==")
        XCTAssertEqual(audio?["sampleRate"]?.intValue, 24000)
        XCTAssertEqual(audio?["numChannels"]?.intValue, 1)

        // Transcript role + threadId.
        let delta = collector.params(for: "thread/realtime/transcript/delta")?.objectValue
        XCTAssertEqual(delta?["threadId"]?.stringValue, "th_voice")
        XCTAssertEqual(delta?["role"]?.stringValue, "assistant")
        XCTAssertEqual(delta?["delta"]?.stringValue, "Hi")
        withExtendedLifetime(session) {}
    }

    func testUserTranscriptionTaggedAsUser() async throws {
        let channel = FakeRealtimeChannel()
        let collector = EmitCollector()
        let session = try await startSession(channel, collector: collector)
        channel.push(.inputTranscriptionCompleted(itemId: "u", transcript: "what time is it"))
        await waitUntil { collector.methods.contains("thread/realtime/transcript/done") }
        let done = collector.params(for: "thread/realtime/transcript/done")?.objectValue
        XCTAssertEqual(done?["role"]?.stringValue, "user")
        XCTAssertEqual(done?["text"]?.stringValue, "what time is it")
        withExtendedLifetime(session) {}
    }

    func testAppendTextForwardsUserTextAndResponseCreate() async throws {
        let channel = FakeRealtimeChannel()
        let collector = EmitCollector()
        let session = try await startSession(channel, collector: collector, modality: "text")
        await session.appendText("ping")
        await waitUntil {
            channel.sent.contains { if case .userText = $0 { return true }; return false }
        }
        XCTAssertTrue(channel.sent.contains { if case .userText(let t) = $0 { return t == "ping" }; return false })
        XCTAssertTrue(channel.sent.contains { if case .createResponse = $0 { return true }; return false })
    }

    func testAppendAudioForwardsBase64Frame() async throws {
        let channel = FakeRealtimeChannel()
        let collector = EmitCollector()
        let session = try await startSession(channel, collector: collector)
        let frame = JSONValue.object([
            "data": .string("QUJD"),
            "sampleRate": .int(24000),
            "numChannels": .int(1),
        ])
        await session.appendAudio(frame)
        await waitUntil {
            channel.sent.contains { if case .appendAudio = $0 { return true }; return false }
        }
        XCTAssertTrue(channel.sent.contains { if case .appendAudio(let b) = $0 { return b == "QUJD" }; return false })
    }

    func testStopEmitsClosedExactlyOnce() async throws {
        let channel = FakeRealtimeChannel()
        let collector = EmitCollector()
        let session = try await startSession(channel, collector: collector)
        await session.stop(reason: "client_stopped")
        await waitUntil { collector.methods.contains("thread/realtime/closed") }
        // A second stop must not emit another closed (idempotent).
        await session.stop(reason: "client_stopped")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(collector.methods.filter { $0 == "thread/realtime/closed" }.count, 1)
        let closed = collector.params(for: "thread/realtime/closed")?.objectValue
        XCTAssertEqual(closed?["reason"]?.stringValue, "client_stopped")
        XCTAssertGreaterThanOrEqual(channel.closes, 1)
    }

    func testServerErrorEmitsClosedWithReason() async throws {
        let channel = FakeRealtimeChannel()
        let collector = EmitCollector()
        let session = try await startSession(channel, collector: collector)
        channel.push(.error(message: "bad key"))
        await waitUntil { collector.methods.contains("thread/realtime/closed") }
        let closed = collector.params(for: "thread/realtime/closed")?.objectValue
        XCTAssertEqual(closed?["reason"]?.stringValue, "error: bad key")
        withExtendedLifetime(session) {}
    }
}
