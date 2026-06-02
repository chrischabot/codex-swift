import Foundation
import WireProtocol
import ModelClient

// MARK: - Realtime voice backend seam
//
// The `thread/realtime/*` JSON-RPC surface has two backends:
//   - the built-in ECHO mock in `RequestRouter` (default; transcript/audio are
//     reflected straight back, useful for wiring + UI tests with no API key),
//   - a LIVE backend that bridges the browser audio stream to OpenAI's Realtime
//     API (`gpt-realtime-2`) via `ModelClient.RealtimeConversation`.
//
// The live backend is injected into `RequestRouter` as a factory so the
// Supervisor stays decoupled from how the connection is built and credentialed
// (codexd is the composition root that flips it on behind a flag). When the
// factory is nil, the echo path runs unchanged — so existing tests and the
// mock UI keep working.

/// Start parameters for one live realtime session, derived from a
/// `thread/realtime/start` request (after the same parsing the echo path uses).
public struct RealtimeStartParams: Sendable {
    public var threadId: String
    /// `"audio"` (speech-to-speech) or `"text"`.
    public var outputModality: String
    public var voice: String?
    /// Resolved realtime backend prompt (the session `instructions`), or nil.
    public var instructions: String?

    public init(threadId: String, outputModality: String,
                voice: String? = nil, instructions: String? = nil) {
        self.threadId = threadId
        self.outputModality = outputModality
        self.voice = voice
        self.instructions = instructions
    }
}

/// Sink for `thread/realtime/*` server notifications: `(method, params)`.
/// `RequestRouter` supplies a closure that wraps each tuple in a
/// `ServerNotification` and sends it down the originating connection.
public typealias RealtimeEmit =
    @Sendable (_ method: String, _ params: JSONValue) async -> Void

/// One active live session for a thread. Forwards user input to the model and
/// streams the model's transcript + audio back through the emit sink. `stop`
/// is idempotent.
public protocol RealtimeBackendSession: Sendable {
    func appendText(_ text: String) async
    func appendAudio(_ audio: JSONValue) async
    func stop(reason: String) async
}

/// Opens a live session for a thread, wiring model output to `emit`. Injected
/// into `RequestRouter`; nil → echo mock.
public typealias RealtimeBackendFactory =
    @Sendable (_ params: RealtimeStartParams, _ emit: @escaping RealtimeEmit)
    async throws -> any RealtimeBackendSession

/// Builds a `RealtimeBackendFactory` backed by `ModelClient.RealtimeConversation`.
/// The composition root (codexd) constructs this with the resolved model id +
/// API key and hands `makeFactory()` to the `RequestRouter` initializer.
public struct LiveRealtimeBackend: Sendable {
    private let sampleRate: Int
    private let channelFactory: @Sendable (RealtimeStartParams) -> any RealtimeChannel

    /// Production initializer: dials the real OpenAI Realtime API.
    public init(model: String, apiKey: String,
                endpoint: String = RealtimeConnection.defaultEndpoint,
                sampleRate: Int = realtimeDefaultSampleRate) {
        self.sampleRate = sampleRate
        self.channelFactory = { _ in
            RealtimeConversation(apiKey: apiKey, model: model, endpoint: endpoint)
        }
    }

    /// Test / custom-transport initializer: inject any `RealtimeChannel`.
    public init(sampleRate: Int = realtimeDefaultSampleRate,
                channelFactory: @escaping @Sendable (RealtimeStartParams) -> any RealtimeChannel) {
        self.sampleRate = sampleRate
        self.channelFactory = channelFactory
    }

    /// Build the `session.update` configuration for a start request.
    static func sessionConfig(for params: RealtimeStartParams) -> RealtimeSessionConfig {
        let modalities = params.outputModality == "text" ? ["text"] : ["audio", "text"]
        return RealtimeSessionConfig(modalities: modalities,
                                     instructions: params.instructions,
                                     voice: params.voice)
    }

    public func makeFactory() -> RealtimeBackendFactory {
        let channelFactory = self.channelFactory
        let sampleRate = self.sampleRate
        return { params, emit in
            let channel = channelFactory(params)
            let session = LiveRealtimeSession(threadId: params.threadId,
                                              channel: channel,
                                              config: Self.sessionConfig(for: params),
                                              sampleRate: sampleRate,
                                              emit: emit)
            try await session.begin()
            return session
        }
    }
}

/// Actor backing one live session. Owns the pump task that translates server
/// events into `thread/realtime/*` notifications, and forwards client input.
actor LiveRealtimeSession: RealtimeBackendSession {
    private let threadId: String
    private let channel: any RealtimeChannel
    private let config: RealtimeSessionConfig
    private let sampleRate: Int
    private let emit: RealtimeEmit
    private var pump: Task<Void, Never>?
    private var closed = false

    init(threadId: String, channel: any RealtimeChannel,
         config: RealtimeSessionConfig,
         sampleRate: Int, emit: @escaping RealtimeEmit) {
        self.threadId = threadId
        self.channel = channel
        self.config = config
        self.sampleRate = sampleRate
        self.emit = emit
    }

    /// Open the channel, apply the session configuration, and start streaming
    /// model output. Throws if the connection cannot be opened (the caller
    /// surfaces it as a closed/error).
    func begin() async throws {
        let stream = try await channel.open()
        // Configure the session before any turns are streamed.
        try await channel.send(.sessionUpdate(config))
        pump = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    if let output = RealtimeOutput.from(event, sampleRate: self.sampleRate) {
                        await self.deliver(output)
                    }
                }
                await self.finish(reason: "completed")
            } catch is CancellationError {
                // Stop initiated locally; `stop` already emitted closed.
            } catch {
                await self.finish(reason: "error: \(error)")
            }
        }
    }

    func appendText(_ text: String) async {
        try? await channel.send(.userText(text))
        // Manual turn: ask the model to respond to the injected message.
        try? await channel.send(.createResponse)
    }

    func appendAudio(_ audio: JSONValue) async {
        guard let base64 = audio["data"]?.stringValue else { return }
        // With server-side VAD configured, appending audio is enough — the
        // model commits the turn and starts a response on detected silence.
        try? await channel.send(.appendAudio(base64: base64))
    }

    func stop(reason: String) async {
        pump?.cancel()
        pump = nil
        await channel.close()
        await finish(reason: reason)
    }

    private func deliver(_ output: RealtimeOutput) async {
        switch output {
        case .transcriptDelta(let role, let delta):
            await emit("thread/realtime/transcript/delta", .object([
                "threadId": .string(threadId),
                "role": .string(role),
                "delta": .string(delta),
            ]))
        case .transcriptDone(let role, let text):
            await emit("thread/realtime/transcript/done", .object([
                "threadId": .string(threadId),
                "role": .string(role),
                "text": .string(text),
            ]))
        case .audio(let base64, let rate, let channels):
            await emit("thread/realtime/outputAudio/delta", .object([
                "threadId": .string(threadId),
                "audio": .object([
                    "data": .string(base64),
                    "sampleRate": .int(Int64(rate)),
                    "numChannels": .int(Int64(channels)),
                ]),
            ]))
        case .error(let message):
            await finish(reason: "error: \(message)")
        case .closed(let reason):
            await finish(reason: reason)
        }
    }

    /// Emit a single `thread/realtime/closed` and stop further output.
    private func finish(reason: String) async {
        guard !closed else { return }
        closed = true
        await emit("thread/realtime/closed", .object([
            "threadId": .string(threadId),
            "reason": .string(reason),
        ]))
    }
}
