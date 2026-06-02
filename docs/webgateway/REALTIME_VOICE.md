# Realtime voice (bidirectional, browser ↔ OpenAI Realtime API)

Status: **code paths in place** (foundation + real client). The live OpenAI
Realtime bridge is implemented and gated; the default backend remains the echo
mock so nothing changes until you opt in. End-to-end live validation against the
real `/v1/realtime` socket is the next step.

## The path

```
browser mic (PCM16 @24k)                          browser speaker
  └─ useRealtimeVoice ──┐                       ┌── useRealtimeVoice playback
                        ▼                       │
  thread/realtime/appendAudio        thread/realtime/{transcript,outputAudio}/*
                        │                       ▲
                 WebGateway WS  (MethodGate allowlists thread/realtime/*)
                        │                       │
                 per-tab RequestRouter ── realtimeBackendFactory? ──┐
                        │  (nil → echo mock)                        │ (live)
                        ▼                                           ▼
              [echo: reflects input]                      LiveRealtimeSession
                                                                    │
                                                          RealtimeConversation
                                                          (URLSessionWebSocketTask)
                                                                    ▼
                                            wss://api.openai.com/v1/realtime?model=gpt-realtime-2
```

## Pieces

- `Sources/ModelClient/RealtimeClient.swift` — the real client: typed
  `RealtimeSessionConfig`, `RealtimeClientEvent` / `RealtimeServerEvent` (tolerant
  decoder handling both classic `response.audio.*` and GA `response.output_audio.*`
  naming), the `RealtimeChannel` transport protocol + the live `RealtimeConversation`
  actor, the `RealtimeConnection` URL/header builders, and the neutral
  `RealtimeOutput` translation. Pure types/codecs build + test on Linux too; only
  the `URLSessionWebSocketTask` dialer is macOS-gated.
- `Sources/Supervisor/RealtimeBackend.swift` — the seam: `RealtimeBackend*`
  protocol/factory + `LiveRealtimeBackend` + `LiveRealtimeSession`, which maps
  `RealtimeOutput` onto the exact `thread/realtime/*` notifications the web
  connector decodes (`connector-codex.ts`). The channel is a dumb transport;
  the session owns the choreography (opening `session.update`, manual-turn
  `userText`+`response.create`, single idempotent `closed`).
- `Sources/Supervisor/RequestRouter.swift` — injects `realtimeBackendFactory`;
  when present, `thread/realtime/*` (except `listVoices`) is delegated to the
  live backend, else the echo mock runs. Live sessions are torn down on
  `connectionClosed` so the upstream WS is never leaked.
- `Sources/codexd/main.swift` — `realtimeBackendFactory()` builds the live
  backend and injects it into the stdio router and every per-tab web router.

## Enabling the live bridge

```sh
CODEXKIT_REALTIME_LIVE=1 OPENAI_API_KEY=sk-… \
  codexd --listen off --listen-web=127.0.0.1:8443
```

- `CODEXKIT_REALTIME_LIVE=1` — opt in (default off → echo backend).
- `OPENAI_API_KEY` — required. The `/v1/realtime` socket is Bearer-authenticated
  and does not accept the ChatGPT OAuth token (same constraint as computer-use).
- `CODEXKIT_REALTIME_MODEL` — override the model (default `gpt-realtime-2`).
- `CODEXKIT_REALTIME_ENDPOINT` — override the wss endpoint (default
  `wss://api.openai.com/v1/realtime`).

## Model registration

`gpt-realtime-2` (and the `gpt-realtime` base) are registered across every
catalog: `Sources/Prompts/Resources/models.json` (128k ctx, 32k out, audio+image
in / text+audio out, `realtime: true`, reasoning), `Tokenizer/ModelCatalog.swift`
(hidden so they stay out of the coding-model picker but resolvable for
context/tokenizer), and `BenchKit/Pricing.swift` (text-token rates). `ModelsCatalog`
gained `outputModalities`, `supportsAudio{Input,Output}`, and `isRealtime(_:)`.

## Tests (offline)

- `Tests/ModelClientTests/RealtimeClientTests.swift` — URL/headers, client-event
  wire shapes, session-config serialization, server-event decode (both namings),
  `RealtimeOutput` translation.
- `Tests/IntegrationTests/RealtimeBridgeTests.swift` — the full bridge via a fake
  `RealtimeChannel`: `session.update` on start, transcript/audio/user-transcript
  translation to the exact `thread/realtime/*` shapes, `appendText`/`appendAudio`
  forwarding, idempotent `closed`, server-error → closed.
- `Tests/PromptsTests/PromptsTests.swift::testModelsCatalogRegistersRealtimeModel`.

## Known follow-ups for live validation (step two)

- The GA `gpt-realtime` session shape nests audio under `audio.{input,output}`;
  `RealtimeSessionConfig` currently emits the broadly-compatible flat shape
  (`input_audio_format`/`output_audio_format`/`turn_detection`). Tune against the
  live API if the GA model rejects the flat fields (use `passthrough`).
- Connection open has no explicit handshake timeout beyond URLSession defaults.
- Audio output sample rate is assumed 24 kHz mono (matches the browser hook).
