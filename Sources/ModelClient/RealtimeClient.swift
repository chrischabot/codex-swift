import Foundation
import WireProtocol

// MARK: - OpenAI Realtime API client (speech-to-speech voice models)
//
// This is the real client path for OpenAI's Realtime API (`/v1/realtime`),
// the transport behind `gpt-realtime` / `gpt-realtime-2`. It is the voice
// sibling of `WebSocketResponsesClient`: where that speaks the *Responses* API
// over a WebSocket, this speaks the *Realtime* API — a bidirectional event
// stream where the browser streams PCM16 mic audio up and the model streams
// PCM16 speech + transcript deltas back.
//
// Layering (deliberate, so the bulk is testable on the portable core):
//   - The typed session config, client/server event enums, their JSON codecs,
//     the connection-plan (URL + headers) builders, and the neutral
//     `RealtimeOutput` translation all live OUTSIDE `#if canImport(Network)`,
//     so they build and unit-test on Linux as well as macOS.
//   - Only `RealtimeConversation` — the live `URLSessionWebSocketTask` dialer —
//     is macOS-gated, mirroring `WebSocketResponsesClient`.
//
// The Supervisor's `LiveRealtimeBackend` drives this through the
// `RealtimeChannel` protocol, which a fake conforms to in tests so the
// browser ↔ `thread/realtime/*` ↔ Realtime-API bridge is exercised without a
// socket.

/// The audio sample rate (Hz) the browser bridge and Realtime API exchange.
/// PCM16 mono at 24 kHz is the Realtime API default and matches the web
/// `useRealtimeVoice` hook (`AudioContext({ sampleRate: 24000 })`).
public let realtimeDefaultSampleRate = 24_000

// MARK: Session configuration

/// Typed `session` object for a `session.update` event. Serializes to the
/// documented Realtime session shape; `passthrough` carries any
/// not-yet-modeled fields verbatim (e.g. `tools`, `tool_choice`,
/// `max_response_output_tokens`) so callers are never blocked on this struct.
public struct RealtimeSessionConfig: Sendable, Equatable {
    /// Output/IO modalities the session emits. Defaults to speech-to-speech.
    public var modalities: [String]
    /// System prompt for the voice session. When nil, no `instructions` field
    /// is sent and the model uses its server-side default.
    public var instructions: String?
    /// Voice id (see `thread/realtime/listVoices`). nil → server default.
    public var voice: String?
    /// Input/output audio encodings. `pcm16` matches the browser bridge.
    public var inputAudioFormat: String
    public var outputAudioFormat: String
    /// When set, enables server-side transcription of the user's mic audio via
    /// the named transcription model (e.g. `gpt-4o-mini-transcribe`).
    public var inputAudioTranscriptionModel: String?
    /// Server-side voice-activity turn detection. When true, the model decides
    /// turn boundaries from the audio stream (so callers need not send an
    /// explicit `response.create` after speech). nil/false → manual turns.
    public var serverVAD: Bool
    /// Reasoning effort for the realtime-2 model (`low`/`medium`/`high`). nil →
    /// server default. Serialized under `session.reasoning.effort`.
    public var reasoningEffort: String?
    /// Verbatim extra `session` fields, merged last (wins on key collision).
    public var passthrough: [String: JSONValue]

    public init(modalities: [String] = ["audio", "text"],
                instructions: String? = nil,
                voice: String? = nil,
                inputAudioFormat: String = "pcm16",
                outputAudioFormat: String = "pcm16",
                inputAudioTranscriptionModel: String? = "gpt-4o-mini-transcribe",
                serverVAD: Bool = true,
                reasoningEffort: String? = nil,
                passthrough: [String: JSONValue] = [:]) {
        self.modalities = modalities
        self.instructions = instructions
        self.voice = voice
        self.inputAudioFormat = inputAudioFormat
        self.outputAudioFormat = outputAudioFormat
        self.inputAudioTranscriptionModel = inputAudioTranscriptionModel
        self.serverVAD = serverVAD
        self.reasoningEffort = reasoningEffort
        self.passthrough = passthrough
    }

    /// Build the `session` object embedded in a `session.update` event.
    public func sessionObject() -> JSONValue {
        var obj: [String: JSONValue] = [
            "modalities": .array(modalities.map(JSONValue.string)),
            "input_audio_format": .string(inputAudioFormat),
            "output_audio_format": .string(outputAudioFormat),
        ]
        if let instructions { obj["instructions"] = .string(instructions) }
        if let voice { obj["voice"] = .string(voice) }
        if let model = inputAudioTranscriptionModel {
            obj["input_audio_transcription"] = .object(["model": .string(model)])
        }
        obj["turn_detection"] = serverVAD
            ? .object(["type": .string("server_vad")])
            : .null
        if let reasoningEffort {
            obj["reasoning"] = .object(["effort": .string(reasoningEffort)])
        }
        for (k, v) in passthrough { obj[k] = v }
        return .object(obj)
    }
}

// MARK: Client → server events

/// Events the client sends up the Realtime socket.
public enum RealtimeClientEvent: Sendable, Equatable {
    /// Configure/reconfigure the session.
    case sessionUpdate(RealtimeSessionConfig)
    /// Append a base64-encoded PCM16 audio chunk to the input buffer.
    case appendAudio(base64: String)
    /// Commit the buffered input audio as a user turn (manual-turn mode).
    case commitAudio
    /// Clear the pending input-audio buffer.
    case clearAudio
    /// Inject a user text message into the conversation.
    case userText(String)
    /// Ask the model to generate a response (manual-turn mode).
    case createResponse
    /// Cancel an in-progress response.
    case cancelResponse
    /// Escape hatch: send a verbatim event object.
    case raw(JSONValue)

    /// The wire JSON object for this event.
    public func wireJSON() -> JSONValue {
        switch self {
        case .sessionUpdate(let config):
            return .object(["type": .string("session.update"),
                            "session": config.sessionObject()])
        case .appendAudio(let base64):
            return .object(["type": .string("input_audio_buffer.append"),
                            "audio": .string(base64)])
        case .commitAudio:
            return .object(["type": .string("input_audio_buffer.commit")])
        case .clearAudio:
            return .object(["type": .string("input_audio_buffer.clear")])
        case .userText(let text):
            return .object([
                "type": .string("conversation.item.create"),
                "item": .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("input_text"),
                        "text": .string(text),
                    ])]),
                ]),
            ])
        case .createResponse:
            return .object(["type": .string("response.create")])
        case .cancelResponse:
            return .object(["type": .string("response.cancel")])
        case .raw(let value):
            return value
        }
    }

    /// Encode to a UTF-8 JSON string suitable for a WebSocket text frame.
    public func encodedString() throws -> String {
        let data = try JSONEncoder().encode(wireJSON())
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: Server → client events

/// Events the server streams down the Realtime socket. The decoder tolerates
/// both the classic (`response.audio.*`) and GA (`response.output_audio.*`)
/// naming families, and keeps every unrecognized type as `.other` rather than
/// failing — new event types must never crash the bridge.
public enum RealtimeServerEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    case speechStarted
    case speechStopped
    /// Incremental transcript of the user's spoken input.
    case inputTranscriptionDelta(itemId: String, delta: String)
    case inputTranscriptionCompleted(itemId: String, transcript: String)
    /// Incremental transcript of the assistant's spoken output.
    case responseTranscriptDelta(itemId: String, delta: String)
    case responseTranscriptDone(itemId: String, transcript: String)
    /// Incremental assistant text (text-modality responses).
    case responseTextDelta(itemId: String, delta: String)
    case responseTextDone(itemId: String, text: String)
    /// Base64 PCM16 assistant speech chunk.
    case responseAudioDelta(itemId: String, base64: String)
    case responseAudioDone(itemId: String)
    case responseDone
    case error(message: String)
    case other(type: String, raw: JSONValue)

    /// Decode a single server frame. Returns nil only for non-object / typeless
    /// frames; unknown but well-formed events decode to `.other`.
    public static func decode(_ value: JSONValue) -> RealtimeServerEvent? {
        guard let type = value["type"]?.stringValue else { return nil }
        let itemId = value["item_id"]?.stringValue ?? ""
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "input_audio_buffer.speech_started": return .speechStarted
        case "input_audio_buffer.speech_stopped": return .speechStopped
        case "conversation.item.input_audio_transcription.delta":
            return .inputTranscriptionDelta(itemId: itemId,
                                            delta: value["delta"]?.stringValue ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscriptionCompleted(itemId: itemId,
                                                transcript: value["transcript"]?.stringValue ?? "")
        case "response.audio_transcript.delta",
             "response.output_audio_transcript.delta":
            return .responseTranscriptDelta(itemId: itemId,
                                            delta: value["delta"]?.stringValue ?? "")
        case "response.audio_transcript.done",
             "response.output_audio_transcript.done":
            return .responseTranscriptDone(itemId: itemId,
                                           transcript: value["transcript"]?.stringValue ?? "")
        case "response.text.delta", "response.output_text.delta":
            return .responseTextDelta(itemId: itemId,
                                      delta: value["delta"]?.stringValue ?? "")
        case "response.text.done", "response.output_text.done":
            return .responseTextDone(itemId: itemId,
                                     text: value["text"]?.stringValue ?? "")
        case "response.audio.delta", "response.output_audio.delta":
            return .responseAudioDelta(itemId: itemId,
                                       base64: value["delta"]?.stringValue ?? "")
        case "response.audio.done", "response.output_audio.done":
            return .responseAudioDone(itemId: itemId)
        case "response.done": return .responseDone
        case "error":
            // `error` is either `{error:{message}}` or a flat `{message}`.
            let msg = value["error"]?["message"]?.stringValue
                ?? value["message"]?.stringValue
                ?? "realtime error"
            return .error(message: msg)
        default:
            return .other(type: type, raw: value)
        }
    }

    /// Decode from a raw WebSocket text frame.
    public static func decode(frame text: String) -> RealtimeServerEvent? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return decode(value)
    }
}

// MARK: Neutral bridge output

/// Transport-neutral output of a realtime session, consumed by the Supervisor
/// and mapped onto `thread/realtime/*` notifications. Decoupling here keeps the
/// OpenAI wire vocabulary out of the app-server protocol layer.
public enum RealtimeOutput: Sendable, Equatable {
    case transcriptDelta(role: String, delta: String)
    case transcriptDone(role: String, text: String)
    case audio(base64: String, sampleRate: Int, numChannels: Int)
    case error(message: String)
    case closed(reason: String)

    /// Map a server event to a neutral output, or nil for purely-internal
    /// events (session lifecycle, speech VAD markers, audio-done) that the
    /// browser bridge does not surface.
    public static func from(_ event: RealtimeServerEvent,
                            sampleRate: Int = realtimeDefaultSampleRate) -> RealtimeOutput? {
        switch event {
        case .responseTranscriptDelta(_, let delta),
             .responseTextDelta(_, let delta):
            return .transcriptDelta(role: "assistant", delta: delta)
        case .responseTranscriptDone(_, let text),
             .responseTextDone(_, let text):
            return .transcriptDone(role: "assistant", text: text)
        case .inputTranscriptionDelta(_, let delta):
            return .transcriptDelta(role: "user", delta: delta)
        case .inputTranscriptionCompleted(_, let transcript):
            return .transcriptDone(role: "user", text: transcript)
        case .responseAudioDelta(_, let base64):
            return .audio(base64: base64, sampleRate: sampleRate, numChannels: 1)
        case .error(let message):
            return .error(message: message)
        case .sessionCreated, .sessionUpdated, .speechStarted, .speechStopped,
             .responseAudioDone, .responseDone, .other:
            return nil
        }
    }
}

// MARK: Channel protocol + connection plan

/// A bidirectional realtime channel — a dumb transport. `RealtimeConversation`
/// is the live implementation; tests substitute a fake that records sent events
/// and yields canned server events. Protocol choreography (sending the opening
/// `session.update`, turn management) lives in the session that drives the
/// channel, not here, so it is identical across the live and fake transports.
public protocol RealtimeChannel: Sendable {
    /// Open the connection and return the server-event stream.
    func open() async throws -> AsyncThrowingStream<RealtimeServerEvent, any Error>
    /// Send a client event.
    func send(_ event: RealtimeClientEvent) async throws
    /// Close the connection.
    func close() async
}

/// Pure builders for the Realtime connection (URL + headers). Static so they
/// are testable without a socket and compile on every platform.
public enum RealtimeConnection {
    public static let defaultEndpoint = "wss://api.openai.com/v1/realtime"
    public static let defaultBeta = "realtime=v1"

    /// `wss://api.openai.com/v1/realtime?model=<model>` (existing query params
    /// on a custom endpoint are preserved).
    public static func url(endpoint: String = defaultEndpoint, model: String) -> URL {
        guard var components = URLComponents(string: endpoint) else {
            return URL(string: "\(defaultEndpoint)?model=\(model)")!
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "model" }
        items.append(URLQueryItem(name: "model", value: model))
        components.queryItems = items
        return components.url ?? URL(string: "\(defaultEndpoint)?model=\(model)")!
    }

    public static func headers(apiKey: String, beta: String = defaultBeta) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "OpenAI-Beta": beta]
    }
}

#if canImport(Network)
import Network

/// Live OpenAI Realtime transport over `URLSessionWebSocketTask`. Mirrors the
/// `WebSocketResponsesClient` framing approach: an ephemeral `URLSession`, one
/// JSON event per text frame, a recursive receive loop feeding an
/// `AsyncThrowingStream`. macOS-gated like the rest of the Network transports;
/// the portable Linux build uses the platform types/codecs above without this
/// dialer.
public actor RealtimeConversation: RealtimeChannel {
    private let url: URL
    private let headers: [String: String]
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var opened = false

    public init(apiKey: String,
                model: String,
                endpoint: String = RealtimeConnection.defaultEndpoint,
                beta: String = RealtimeConnection.defaultBeta) {
        self.url = RealtimeConnection.url(endpoint: endpoint, model: model)
        self.headers = RealtimeConnection.headers(apiKey: apiKey, beta: beta)
    }

    public func open() async throws -> AsyncThrowingStream<RealtimeServerEvent, any Error> {
        guard !opened else {
            throw ModelError("realtime session already opened", retryable: false)
        }
        opened = true
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task

        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: RealtimeServerEvent.self)

        // The receive loop runs on URLSession's delegate queue (off-actor); it
        // only touches the Sendable `task` + `continuation`.
        @Sendable func receive() {
            task.receive { result in
                switch result {
                case .failure(let error):
                    continuation.finish(throwing:
                        ModelError("realtime receive failed: \(error)", retryable: true))
                case .success(let message):
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: text = ""
                    }
                    if let event = RealtimeServerEvent.decode(frame: text) {
                        continuation.yield(event)
                    }
                    receive()
                }
            }
        }

        continuation.onTermination = { [weak self] _ in
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            Task { await self?.markClosed() }
        }

        task.resume()
        receive()
        return stream
    }

    public func send(_ event: RealtimeClientEvent) async throws {
        guard let task else {
            throw ModelError("realtime session is not open", retryable: false)
        }
        let json = try event.encodedString()
        do {
            try await task.send(.string(json))
        } catch {
            throw ModelError("realtime send failed: \(error)", retryable: true)
        }
    }

    public func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        markClosed()
    }

    private func markClosed() {
        task = nil
        session = nil
    }
}
#endif
