import XCTest
import Foundation
import WireProtocol
@testable import ModelClient

/// Offline coverage for the OpenAI Realtime API client (`RealtimeClient.swift`):
/// connection plan (URL + headers), client-event wire shapes, session-config
/// serialization, server-event decoding (both classic and GA naming), and the
/// neutral `RealtimeOutput` translation the Supervisor bridge consumes.
final class RealtimeClientTests: XCTestCase {

    // MARK: Connection plan

    func testRealtimeURLAddsModelQuery() {
        let url = RealtimeConnection.url(model: "gpt-realtime-2")
        XCTAssertEqual(url.absoluteString,
                       "wss://api.openai.com/v1/realtime?model=gpt-realtime-2")
    }

    func testRealtimeURLOverridesExistingModelAndPreservesEndpoint() {
        let url = RealtimeConnection.url(
            endpoint: "wss://example.test/v1/realtime?model=old&foo=bar",
            model: "gpt-realtime-2")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "example.test")
        let items = comps.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "model" }.map(\.value), ["gpt-realtime-2"])
        XCTAssertTrue(items.contains { $0.name == "foo" && $0.value == "bar" })
    }

    func testConnectHeaders() {
        let headers = RealtimeConnection.headers(apiKey: "sk-test")
        XCTAssertEqual(headers["Authorization"], "Bearer sk-test")
        XCTAssertEqual(headers["OpenAI-Beta"], "realtime=v1")
    }

    // MARK: Client events

    private func wire(_ event: RealtimeClientEvent) -> [String: JSONValue] {
        guard case let .object(o) = event.wireJSON() else { return [:] }
        return o
    }

    func testAppendAudioEventShape() {
        let o = wire(.appendAudio(base64: "QUJD"))
        XCTAssertEqual(o["type"]?.stringValue, "input_audio_buffer.append")
        XCTAssertEqual(o["audio"]?.stringValue, "QUJD")
    }

    func testUserTextEventShape() {
        let o = wire(.userText("hello there"))
        XCTAssertEqual(o["type"]?.stringValue, "conversation.item.create")
        let item = o["item"]?.objectValue
        XCTAssertEqual(item?["type"]?.stringValue, "message")
        XCTAssertEqual(item?["role"]?.stringValue, "user")
        let content = item?["content"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(content?["type"]?.stringValue, "input_text")
        XCTAssertEqual(content?["text"]?.stringValue, "hello there")
    }

    func testControlEventShapes() {
        XCTAssertEqual(wire(.commitAudio)["type"]?.stringValue, "input_audio_buffer.commit")
        XCTAssertEqual(wire(.clearAudio)["type"]?.stringValue, "input_audio_buffer.clear")
        XCTAssertEqual(wire(.createResponse)["type"]?.stringValue, "response.create")
        XCTAssertEqual(wire(.cancelResponse)["type"]?.stringValue, "response.cancel")
    }

    func testEncodedStringIsValidJSON() throws {
        let s = try RealtimeClientEvent.appendAudio(base64: "AAAA").encodedString()
        let data = s.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "input_audio_buffer.append")
    }

    // MARK: Session config

    func testSessionUpdateAppliesConfig() {
        let config = RealtimeSessionConfig(
            modalities: ["audio", "text"],
            instructions: "Be brief.",
            voice: "marin",
            reasoningEffort: "low")
        let o = wire(.sessionUpdate(config))
        XCTAssertEqual(o["type"]?.stringValue, "session.update")
        let s = o["session"]?.objectValue
        XCTAssertEqual(s?["modalities"]?.arrayValue?.compactMap(\.stringValue), ["audio", "text"])
        XCTAssertEqual(s?["instructions"]?.stringValue, "Be brief.")
        XCTAssertEqual(s?["voice"]?.stringValue, "marin")
        XCTAssertEqual(s?["input_audio_format"]?.stringValue, "pcm16")
        XCTAssertEqual(s?["output_audio_format"]?.stringValue, "pcm16")
        XCTAssertEqual(s?["turn_detection"]?.objectValue?["type"]?.stringValue, "server_vad")
        XCTAssertEqual(s?["input_audio_transcription"]?.objectValue?["model"]?.stringValue,
                       "gpt-4o-mini-transcribe")
        XCTAssertEqual(s?["reasoning"]?.objectValue?["effort"]?.stringValue, "low")
    }

    func testSessionConfigManualTurnsAndNoVoice() {
        let config = RealtimeSessionConfig(voice: nil, serverVAD: false,
                                           passthrough: ["temperature": .double(0.7)])
        guard case let .object(s) = config.sessionObject() else { return XCTFail("not object") }
        XCTAssertNil(s["voice"])
        XCTAssertTrue(s["turn_detection"]?.isNull == true)
        XCTAssertEqual(s["temperature"]?.doubleAsDouble, 0.7)
    }

    // MARK: Server events

    func testDecodeAssistantTranscriptDeltaClassicAndGA() {
        let classic = RealtimeServerEvent.decode(frame:
            #"{"type":"response.audio_transcript.delta","item_id":"i1","delta":"Hel"}"#)
        XCTAssertEqual(classic, .responseTranscriptDelta(itemId: "i1", delta: "Hel"))
        let ga = RealtimeServerEvent.decode(frame:
            #"{"type":"response.output_audio_transcript.delta","item_id":"i1","delta":"lo"}"#)
        XCTAssertEqual(ga, .responseTranscriptDelta(itemId: "i1", delta: "lo"))
    }

    func testDecodeAudioDeltaBothNamings() {
        let classic = RealtimeServerEvent.decode(frame:
            #"{"type":"response.audio.delta","item_id":"i1","delta":"QkJC"}"#)
        XCTAssertEqual(classic, .responseAudioDelta(itemId: "i1", base64: "QkJC"))
        let ga = RealtimeServerEvent.decode(frame:
            #"{"type":"response.output_audio.delta","item_id":"i1","delta":"QkJC"}"#)
        XCTAssertEqual(ga, .responseAudioDelta(itemId: "i1", base64: "QkJC"))
    }

    func testDecodeInputTranscription() {
        XCTAssertEqual(
            RealtimeServerEvent.decode(frame:
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"what time is it"}"#),
            .inputTranscriptionCompleted(itemId: "u1", transcript: "what time is it"))
    }

    func testDecodeErrorAndUnknown() {
        XCTAssertEqual(
            RealtimeServerEvent.decode(frame: #"{"type":"error","error":{"message":"bad key"}}"#),
            .error(message: "bad key"))
        let unknown = RealtimeServerEvent.decode(frame:
            #"{"type":"rate_limits.updated","x":1}"#)
        if case let .other(type, _) = unknown {
            XCTAssertEqual(type, "rate_limits.updated")
        } else {
            XCTFail("expected .other, got \(String(describing: unknown))")
        }
    }

    func testDecodeRejectsTypelessFrame() {
        XCTAssertNil(RealtimeServerEvent.decode(frame: #"{"no_type":true}"#))
        XCTAssertNil(RealtimeServerEvent.decode(frame: "not json"))
    }

    // MARK: Neutral translation

    func testTranslationAssistantTranscript() {
        XCTAssertEqual(
            RealtimeOutput.from(.responseTranscriptDelta(itemId: "i", delta: "hi")),
            .transcriptDelta(role: "assistant", delta: "hi"))
        XCTAssertEqual(
            RealtimeOutput.from(.responseTextDone(itemId: "i", text: "done")),
            .transcriptDone(role: "assistant", text: "done"))
    }

    func testTranslationUserTranscript() {
        XCTAssertEqual(
            RealtimeOutput.from(.inputTranscriptionDelta(itemId: "u", delta: "yo")),
            .transcriptDelta(role: "user", delta: "yo"))
    }

    func testTranslationAudioCarriesSampleRate() {
        XCTAssertEqual(
            RealtimeOutput.from(.responseAudioDelta(itemId: "i", base64: "QQ=="), sampleRate: 24000),
            .audio(base64: "QQ==", sampleRate: 24000, numChannels: 1))
    }

    func testTranslationDropsInternalEvents() {
        XCTAssertNil(RealtimeOutput.from(.sessionCreated))
        XCTAssertNil(RealtimeOutput.from(.speechStarted))
        XCTAssertNil(RealtimeOutput.from(.responseDone))
        XCTAssertNil(RealtimeOutput.from(.responseAudioDone(itemId: "i")))
    }
}

private extension JSONValue {
    /// Convenience for asserting a numeric passthrough value regardless of
    /// whether it decoded as int or double.
    var doubleAsDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}
