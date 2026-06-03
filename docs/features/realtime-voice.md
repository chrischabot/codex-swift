# Realtime Voice

*Talk to the agent with your voice in the browser: stream mic audio up, hear spoken replies and live transcripts back, bridged to OpenAI's Realtime API behind a single opt-in flag.*

## Why it matters

Typing is the wrong interface for some moments. You are pair-debugging with your hands on the keyboard, or driving, or just want to think out loud — and switching to a text box breaks the flow. A speech-to-speech agent lets you keep talking while it answers in a natural voice, with the transcript rendered live so nothing is lost.

The hard part is that this is not a normal request/response call. Voice means a *bidirectional* audio stream: your microphone PCM flows up continuously, the model's speech and transcript stream down in deltas, and turn-taking has to feel natural. codex-swift wires that whole loop — browser mic to model and back — so you do not have to build the audio plumbing, the WebSocket choreography, or the turn detection yourself. And because it ships off by default behind a flag, the web UI keeps working with zero API cost until you decide to turn real voice on.

## What it is

Realtime Voice is the speech-to-speech surface of the agent. In the WebGateway browser UI a thread can open a voice session: you click to start, the page captures your microphone, and you hear the agent speak back while a running transcript of both sides appears on screen.

Under the hood there are **two backends** behind the same browser protocol:

- **Echo mock (default).** Audio and text you send are reflected straight back. No API key, no cost, no network to OpenAI. This is what runs out of the box, and it is enough to wire up and test the entire browser round-trip.
- **Live OpenAI Realtime (opt-in).** The agent's audio is bridged to OpenAI's `/v1/realtime` WebSocket, driving the `gpt-realtime-2` voice model. You speak; the real model listens, reasons, and speaks back.

The browser code does not change between the two. The same `thread/realtime/*` messages flow either way — only the server-side backend differs, selected by an environment flag at startup.

## How it works

The path from your mic to the model and back:

```
browser mic (PCM16 @24k)                           browser speaker
  └─ useRealtimeVoice ──┐                        ┌── useRealtimeVoice playback
                        ▼                        │
   thread/realtime/appendAudio     thread/realtime/{transcript,outputAudio}/*
                        │                        ▲
              WebGateway WS  (MethodGate allowlists thread/realtime/*)
                        │                        │
              per-tab RequestRouter ── realtimeBackendFactory? ──┐
                        │  (nil → echo mock)                     │ (live)
                        ▼                                        ▼
              [echo: reflects input]                    LiveRealtimeSession
                                                                 │
                                                       RealtimeConversation
                                                       (URLSessionWebSocketTask)
                                                                 ▼
                              wss://api.openai.com/v1/realtime?model=gpt-realtime-2
```

Key concepts, in the order audio travels:

- **Browser hook (`useRealtimeVoice`).** Captures the mic at 24 kHz mono, converts each frame to PCM16, base64-encodes it, and sends `thread/realtime/appendAudio`. It also subscribes to output: transcript deltas accumulate into live lines, and audio deltas are decoded back to PCM and played through an `AudioContext`. The page speaks the same PCM16-at-24kHz dialect at both ends.
- **The gateway gate.** Inbound messages cross a deny-default allowlist (`MethodGate` in `Sources/WebGateway/Security.swift`). The five voice methods — `listVoices`, `start`, `appendText`, `appendAudio`, `stop` — are explicitly allowed; nothing is granted implicitly.
- **The router seam.** Each browser tab gets a `RequestRouter`. If a live backend factory was injected at startup, every `thread/realtime/*` request (except `listVoices`) is delegated to the live backend; otherwise the built-in echo path runs. Live sessions are torn down on `connectionClosed`, so a closed browser tab never leaks the upstream socket.
- **The live bridge (`LiveRealtimeSession` + `RealtimeConversation`).** The *session* owns the choreography: it opens the channel, sends the opening `session.update` to configure modalities/voice/instructions, forwards your input, and pumps the model's events back out. The *conversation* is a dumb transport — a `URLSessionWebSocketTask` to `wss://api.openai.com/v1/realtime`, one JSON event per text frame.
- **Neutral translation.** The OpenAI wire vocabulary never leaks into the browser protocol. A `RealtimeServerEvent` decoder tolerates both the classic (`response.audio.*`) and GA (`response.output_audio.*`) event names — and keeps any unknown event as `.other` rather than crashing — then `RealtimeOutput` maps the meaningful ones onto the exact `thread/realtime/transcript/{delta,done}` and `thread/realtime/outputAudio/delta` notifications the browser already understands.

**Turn-taking** defaults to server-side voice-activity detection (`serverVAD`): with VAD on, simply streaming mic audio is enough — the model detects when you stop talking, commits the turn, and starts speaking. Injected *text* turns use a manual turn (`userText` + `response.create`).

A deliberate layering note: every type, codec, and URL/header builder lives *outside* the macOS `Network` gate, so the bulk is unit-testable on Linux. Only the live `URLSessionWebSocketTask` dialer is macOS-gated.

## Using it

The default needs nothing — the echo backend is always on, so the voice UI round-trips immediately. To bridge to the real model, set the flag and a key when launching `codexd`:

```sh
CODEXKIT_REALTIME_LIVE=1 OPENAI_API_KEY=sk-… \
  codexd --listen off --listen-web=127.0.0.1:8443
```

Configuration (all read at startup, in `Sources/codexd/main.swift`):

- **`CODEXKIT_REALTIME_LIVE=1`** — opt in. Anything else (including unset) keeps the echo backend.
- **`OPENAI_API_KEY`** — required for live. The `/v1/realtime` socket is Bearer-authenticated and does **not** accept the ChatGPT OAuth token (same constraint as computer-use). If the flag is `1` but the key is missing, codexd logs a warning to stderr and quietly falls back to echo.
- **`CODEXKIT_REALTIME_MODEL`** — override the voice model (default `gpt-realtime-2`).
- **`CODEXKIT_REALTIME_ENDPOINT`** — override the wss endpoint (default `wss://api.openai.com/v1/realtime`).

On a successful live start codexd logs `codexd: realtime voice backend = live (model=gpt-realtime-2)` to stderr. In the browser, open a thread's voice session: you click start, the browser prompts for mic permission, you speak, and you both hear the reply and watch the transcript fill in for the user and assistant roles. Voice ids come from `thread/realtime/listVoices` (always served by the router, even in live mode).

`gpt-realtime-2` and the `gpt-realtime` base are registered across the catalogs (`models.json`, the tokenizer `ModelCatalog`, BenchKit pricing). They are intentionally **hidden** from the coding-model picker — they drive the voice bridge, not the Responses-API agent turn loop — but remain resolvable for context and tokenization.

## What it enables

- **Hands-free agent interaction** in the browser UI, composing with the same threads, tools, and history as the typed surface — the voice session attaches to an existing `threadId`.
- **A safe demo/dev default.** Because the echo mock is the default backend, the entire front-end (mic capture, PCM codec, playback, transcript rendering) can be built and tested with no key and no spend; flipping `CODEXKIT_REALTIME_LIVE=1` swaps in the real model with no front-end change.
- **A clean transport seam.** The `RealtimeChannel` protocol means the live OpenAI dialer is one implementation; tests substitute a fake channel to exercise the whole browser ↔ bridge ↔ model path without a socket.

This is part of the WebGateway surface — see the gateway and its security model in `../webgateway/` for how the WS handshake, Origin checks, and method allowlist gate every voice message.

## Status

The code paths are **in place and gated**; the default backend remains the echo mock. End-to-end validation against the real `/v1/realtime` socket is the next step. Known live-tuning follow-ups: the GA `gpt-realtime` session shape nests audio under `audio.{input,output}` while `RealtimeSessionConfig` currently emits the broadly-compatible *flat* shape (`input_audio_format` / `output_audio_format` / `turn_detection`) — use the config's `passthrough` to adjust if the GA model rejects the flat fields; connection open has no explicit handshake timeout beyond URLSession defaults; and output audio is assumed 24 kHz mono (matching the browser hook).

## Go deeper

Internals and reference: `docs/webgateway/REALTIME_VOICE.md`.
