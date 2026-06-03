# Models & Providers

*How the agent talks to a model: one Responses-API protocol, three interchangeable transports with session-sticky fallback, a capability catalog, and a separate cheap "small model" lane for extensions.*

## Why it matters

An AI coding agent lives or dies by its connection to the model. That connection is hostile: the network drops mid-stream, OpenAI returns `429`s and `503`s under load, a long turn overruns the context window, and a token expires after 401. If the agent treats the model as a simple request/response call, every one of those becomes a crash or a silent wrong answer.

Picture a 20-minute refactor turn. Forty seconds in, the WebSocket the agent opened gets reset. A naive client surfaces an error and the whole turn dies — you lose the work and start over. You also want the model to *stream* its thinking so you see progress, and you want it to use the cheapest correct transport without you configuring anything. Separately, an extension wants to label a memory note — and paying full agent-model rates (or routing that through the careful agent loop) for a one-line classification is wasteful.

This subsystem makes all of that disappear. One protocol, several resilient transports, automatic retry and fallback, a catalog that knows each model's quirks, and a side door for cheap utility calls.

## What it is

A small set of cooperating pieces that together answer "send this prompt to a model and stream back the response, reliably":

- **`ModelClient`** — the single protocol every model path implements. You hand it a `Prompt` and `ModelSettings`; it hands back a `ResponseStream` of typed events (`created`, `agentDelta`, `agentDone`, `toolCall`, `completed`). The agent loop only ever sees this shape — it never knows or cares which transport ran underneath.
- **Three transports** that all speak OpenAI's **Responses API** but frame it differently: curl-backed SSE (portable), native macOS `URLSession` SSE (production default), and Responses-over-WebSocket (lowest latency, prewarm).
- **Wrapper clients** that add resilience without the agent loop knowing: retry/backoff, session-sticky WS→HTTPS fallback, and 401 token-refresh.
- **A model catalog** (`models.json`, decoded by `ModelsCatalog`) that records each model's capabilities — reasoning, parallel tool calls, image/audio support, service tiers, apply_patch tool flavor — so the request is shaped correctly per model.
- **A provider registry** (`ModelProvider` / `ModelProviderRegistry`) describing *where* to send the request: base URL, auth env var, headers, WebSocket support. OpenAI is built in; you can add more.
- **The small/utility model** (`SmallModel`) — a completely separate, chat-completions lane for cheap JSON sub-tasks, exposed only to extensions. It never touches the agent's own model loop.

## How it works

Everything funnels through one method:

```swift
func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream
```

The `ResponseStream` carries an `AsyncThrowingStream<ResponseEvent, Error>` plus a `LastResponseBox`. The wire format is Server-Sent Events: the server emits `data: {…}` frames, each with a `type` discriminator (`response.created` → `response.output_text.delta` → `response.output_item.done` → `response.completed`), which the transports map to the typed `ResponseEvent` cases. The agent loop consumes the same events regardless of transport.

**Layered client stack.** The composition root (`Sources/codexd/main.swift`) builds the client as a stack of decorators, outermost first:

```
AuthRefreshingModelClient   (401 → refresh token → retry)
  └─ TransportFallbackModelClient   (WS primary, HTTPS fallback — session-sticky)
       ├─ WebSocketResponsesClient        (primary, when CODEXKIT_RESPONSES_WEBSOCKET=1)
       └─ URLSessionResponsesClient        (fallback / default macOS path)
```

Two resilience behaviors deserve a mental model:

- **Session-sticky fallback.** `TransportFallbackModelClient` retries the WebSocket up to a bounded budget (full-jitter backoff, guarded by a per-session token bucket). If WS keeps failing, it engages HTTPS **for the rest of the session** and never tries WS again on that instance. Crucially it watches for failures *inside* the already-opened event stream — a WS dropped mid-response is caught and re-routed, so your 20-minute turn survives the reset.
- **Retry vs. terminal.** Errors are classified (`ModelClientErrorClassifier`) into retryable (`429`, `5xx`, `server_is_overloaded`, `rate_limit_exceeded`, `context_window_exceeded`) vs. terminal (`insufficient_quota`, `invalid_prompt`, `cyber_policy`). A `response.incomplete` with reason `max_output_tokens` is treated as a **soft success** — the model produced everything it was budgeted for, so retrying would just loop.

**One request body, three framings.** `OpenAIResponsesClient.buildRequestBody` is the single source of truth for the JSON body. WebSocket reuses it and just adds `"type": "response.create"` and strips `stream`/`background`. So the bytes on the wire are identical across transports — only the framing differs.

**Catalog shapes the request.** Before sending, the `SessionEngine` looks up the model slug in `ModelsCatalog` and gates wire fields accordingly: `parallel_tool_calls` only when `supports_parallel_tool_calls` is set; `reasoning` only for reasoning models (defaulting effort to the catalog's `default_reasoning_level`); `text.verbosity` dropped when the model doesn't support it; `service_tier` dropped when the model doesn't advertise it; the freeform (`type:"custom"`) apply_patch tool downgraded to a plain function tool for models that lack it (otherwise OpenAI rejects with `400 Invalid value: 'custom'`). Unknown slugs fall back to safe defaults.

**`store` + `previous_response_id` coupling.** The turn loop chains responses within a turn via `previous_response_id`, which OpenAI only allows if the prior response was stored. So `ModelSettings.store` defaults to `true`, and the builder forces `store: true` whenever `previousResponseId` is set, regardless of caller intent.

## Using it

**Default behavior (zero config).** Set `OPENAI_API_KEY` and run the daemon. `codexd` builds the client automatically: on macOS it uses `URLSessionResponsesClient` against `https://api.openai.com/v1/responses`; off-macOS it uses the portable curl client. The default model slug is **`gpt-5.5`**.

**Key environment variables** (read in `codexd/main.swift`):

- `OPENAI_API_KEY` — bearer credential. Absent → the daemon tries broker/stored auth, else a `NotConfiguredModelClient`.
- `OPENAI_BASE_URL` — override the endpoint root (trailing `/responses` is appended).
- `CODEXKIT_RESPONSES_WEBSOCKET=1` — opt into the WebSocket transport with HTTPS fallback (macOS only).
- `CODEXKIT_WS_PREWARM` — set to `0` to disable prewarm (default on); prewarm sends a non-generating frame first to warm the server's prompt cache.
- `CODEXKIT_MOCK=1` — use the deterministic `MockModelClient` (with `CODEXKIT_MOCK_SCENARIO=tool-loop-compact` for the compaction ladder). Great for tests and offline runs.

**Supported models** (bundled `Sources/Prompts/Resources/models.json`, 8 entries):

| Slug | Modalities (in / out) | Reasoning | Parallel tools | Notes |
| --- | --- | --- | --- | --- |
| `gpt-5.5` | text, image / text | yes | yes | default agent model |
| `gpt-5.4` | text, image / text | yes | yes | |
| `gpt-5.4-mini` | text, image / text | yes | yes | |
| `gpt-5.3-codex` | text, image / text | yes | yes | codex-tuned |
| `gpt-5.2` | text, image / text | yes | yes | |
| `codex-auto-review` | text, image / text | yes | yes | review sub-agent |
| `gpt-realtime-2` | text, audio, image / text, audio | yes | — | voice (see below) |
| `gpt-realtime` | text, audio, image / text, audio | — | — | voice (see below) |

The two `gpt-realtime*` slugs are **not** used by the Responses-API agent turn loop. They are speech-to-speech voice models served over `/v1/realtime` (`RealtimeClient`), driving the voice bridge — see the Realtime voice page.

**Adding a provider.** Providers come from config (`model_providers` map). Each entry maps to a `ModelProvider` with `base_url`, `env_key`, optional `http_headers`/`env_http_headers`, `query_params`, `requires_openai_auth`, `supports_websockets`. Only `wire_api = "responses"` is accepted — `wire_api = "chat"` hard-errors with a remediation message (Chat Completions was removed upstream). The built-in `openai` provider is always present unless overridden. Azure Responses endpoints are auto-detected and (like OpenAI) qualify for server-side remote compaction.

**Using the small/utility model.** This is a separate API for extensions:

```swift
let small = LocalSmallModel(model: chatClient, modelId: "llama3.2")
let label: Label = try await small.json(
    SmallTask(prompt: "Classify this note", input: noteText), as: Label.self)
```

`json(_:as:)` runs a JSON-only sub-task: `T: Decodable` *is* the schema, an invalid reply triggers one corrective retry, and it never returns garbage. It's backed by `ChatCompletionsClient`, which speaks `POST {baseURL}/v1/chat/completions` — point it at ollama (`http://localhost:11434`), lmstudio (`http://localhost:1234`), or OpenAI. It runs tools-disabled and is wired in by the extension, **never** through `ModelProviderRegistry` or the agent path.

## What it enables

- **Resilient long turns.** The retry + session-sticky fallback layers mean a single transport hiccup doesn't kill a multi-minute agent turn — the engine above never sees the churn.
- **Correct-by-construction requests.** Because the catalog gates reasoning, parallel tool calls, verbosity, service tier, and the apply_patch flavor per model, you can swap models without hand-editing request fields. This feeds [Prompts & instructions](./prompts-and-context.md) (the catalog also supplies per-model, per-personality `instructions`) and the [Tools](./tools.md) layer (shell-tool family and apply_patch downgrade).
- **Provider portability.** The provider registry lets you target Azure or a self-hosted Responses-compatible endpoint with config alone.
- **Cheap side work for extensions.** The small-model lane lets features like the Memory Wiki do labeling/scoring/routing on a local or cheap endpoint, keeping those tokens off the agent's metered Responses budget. Token and rate-limit telemetry from the main path (`UsageSnapshot`, `RateLimitSnapshot`, `UsageTracker`) flows up to the client as `thread/tokenUsage/updated` and `account/rateLimits/updated`.

## Status

The small/utility model and its `ChatCompletionsClient` are **macOS-only** and **extension-only** by design — they are not plumbed into the agent loop. The `gpt-realtime*` voice models are a separate path; the live OpenAI Realtime client is gated behind `CODEXKIT_REALTIME_LIVE` and defaults to an echo mock. The bundled `models.json` is a static snapshot copied from upstream `codex-rs/models-manager`; codex-swift does not yet refresh it from the remote `/models` endpoint.

## Go deeper

Full internals — request-body field-by-field, the complete SSE/error-code mapping, WebSocket handshake + prewarm, retry token-bucket math, `output_schema` plumbing, and the mock client — are in [`docs/MODEL_CLIENT.md`](../MODEL_CLIENT.md).
