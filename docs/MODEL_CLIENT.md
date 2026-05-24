# Model Client (OpenAI Responses API)

This document describes how codex-swift talks to OpenAI's Responses API.
It is the authoritative reference for the request body shape, the SSE
event stream, error classification, the three concrete transports (curl,
URLSession, WebSocket), the session-sticky transport-fallback wrapper,
retry policy, and the deterministic mock used in tests.

The implementation lives in `Sources/ModelClient/`:

- `ModelClient.swift` — the `ModelClient` protocol plus `Prompt`,
  `ToolSpec`, `ModelSettings`, `ResponseEvent`, `ModelError`,
  `CodexErrorCode`, `ModelClientErrorClassifier`, `LastResponseBox`.
- `OpenAIResponsesClient.swift` — portable curl-backed SSE client. Owns
  the canonical request-body builder (`buildRequestBody`) used by every
  transport.
- `URLSessionResponsesClient.swift` — native macOS SSE client.
- `WebSocketResponsesClient.swift` — Responses-over-WebSocket client.
- `TransportFallbackModelClient.swift` — session-sticky WS→HTTPS fallback.
- `RetryingModelClient.swift` — retry / backoff wrapper.
- `AuthRefreshingModelClient.swift` — auth-refresh decorator (401 →
  refresh broker → retry).
- `MockModelClient.swift` — deterministic scripted client for tests.
- `RecordingModelClient.swift` — observer for unit-test assertions.
- `StreamMapper.swift` — bounded stream + consumer-dropped cancellation.

## 1. Overview

The OpenAI Responses API endpoint is `POST /v1/responses` with
`stream: true` in the JSON body. The wire format is Server-Sent Events:
the server emits `data: { ... }\n` frames terminated by `data: [DONE]`,
each frame carrying one event object with a `type` discriminator. The
canonical happy path is:

1. `response.created` — server acknowledges the request, surfaces a
   `response.id`.
2. `response.output_text.delta` — incremental tokens of an assistant
   message.
3. `response.output_item.done` — a tool call or message item is complete.
4. `response.completed` — the response is final, `usage` is populated.

codex-swift exposes this stream uniformly via the
`ResponseStream` type:

```swift
public protocol ModelClient: Sendable {
    func stream(_ prompt: Prompt, _ settings: ModelSettings)
        async throws -> ResponseStream
}

public struct ResponseStream: Sendable {
    public let events: AsyncThrowingStream<ResponseEvent, any Error>
    public let lastResponse: LastResponseBox
}
```

`ResponseEvent` is the engine-facing shape, decoupled from the SSE wire:

```swift
public enum ResponseEvent: Sendable, Equatable {
    case created
    case agentDelta(itemId: String, delta: String)
    case agentDone(itemId: String, text: String)
    case toolCall(callId: String, name: String, argumentsJSON: String)
    case completed(responseId: String, totalTokens: Int, endTurn: Bool,
                   usage: UsageSnapshot? = nil)
}
```

Three transports implement this protocol. They share the request-body
builder (`OpenAIResponsesClient.buildRequestBody`) so the wire bytes are
identical across transports — only framing differs.

- **`OpenAIResponsesClient`** — portable curl-backed SSE. Spawns
  `curl -sS -N` and streams stdout. Headers (incl. `Authorization`) are
  written into a 0600 curl config file, not argv. Works on every host
  with `curl` (every macOS + Linux box). This is the **default** in
  portable contexts and in CI.
- **`URLSessionResponsesClient`** — native macOS / iOS SSE via
  `URLSession.bytes(for:)`. Production macOS path; no subprocess.
- **`WebSocketResponsesClient`** — Responses-over-WebSocket. Lowest
  latency, supports prewarm. Used by remote-execution and on opt-in for
  the macOS production path. Falls back to HTTPS via
  `TransportFallbackModelClient`.

## 2. Request body

`OpenAIResponsesClient.buildRequestBody(_:_:maxOutputTokens:)` is the
single source of truth for the request body. It mirrors upstream Rust
`ResponsesApiRequest` in `codex-rs/codex-api/src/common.rs` and the
populating function `build_responses_request` in
`codex-rs/core/src/client.rs`.

Top-level keys (snake_case, in canonical order):

```json
{
  "model": "gpt-5.1-codex",
  "instructions": "You are Codex...",
  "input": [
    { "role": "developer",
      "content": [ { "type": "input_text", "text": "..." } ] },
    { "role": "user",
      "content": [ { "type": "input_text", "text": "hello" } ] }
  ],
  "stream": true,
  "prompt_cache_key": "thr_a1b2",
  "tool_choice": "auto",
  "parallel_tool_calls": false,
  "store": true,
  "previous_response_id": "resp_xyz",
  "tools": [
    { "type": "function",
      "name": "shell_command",
      "description": "Run a shell command.",
      "parameters": { "type": "object", "properties": { ... } },
      "output_schema": { "type": "object", "properties": { ... } }
    }
  ],
  "max_output_tokens": 8192,
  "reasoning": { "effort": "medium", "summary": "auto" },
  "include": [ "reasoning.encrypted_content" ],
  "service_tier": "auto",
  "text": { "verbosity": "medium" },
  "client_metadata": { "x-codex-installation-id": "fed5f7e1-..." }
}
```

Field-by-field:

- **`model`** — model slug from `ModelSettings.model`.
- **`instructions`** — system / developer instructions; goes into
  `Prompt.instructions`.
- **`input`** — the entire transcript. Each `PromptInput` is encoded:
  - `.userText(t)` → `{ role: "user", content: [{ type: "input_text", text: t }] }`
  - `.developerText(t)` → `{ role: "developer", content: [{ type: "input_text", text: t }] }`
  - `.assistantText(t)` → `{ role: "assistant", content: [{ type: "output_text", text: t }] }`
  - `.toolOutput(callId, output)` → two items: a synthetic
    `function_call` (`name: "tool"`, `arguments: "{}"`) followed by a
    `function_call_output` carrying the result. The synthetic
    `function_call` is required by the API — a `function_call_output`
    that does not follow a matching `function_call` is rejected.
- **`stream`** — always `true`. The WebSocket transport strips this key
  (along with `background`) before sending.
- **`prompt_cache_key`** — the thread id. Matches upstream contract: the
  server uses this for prompt caching, so the full transcript is cheap to
  re-send.
- **`tool_choice`** — defaults to `"auto"`. Pass `"none"` to forbid tool
  calls, `"required"` to force one.
- **`parallel_tool_calls`** — defaults to `false`. Upstream
  `Prompt::default()` (`client_common.rs:56`) is also `false`; the value
  is plumbed from model-info capabilities in upstream. Until codex-swift
  ships a model-info table, callers that know the model supports it pass
  `parallelToolCalls: true` explicitly.
- **`store`** — defaults to `true` (see §3 for why). Controls whether
  OpenAI persists the response so a later request can reference it via
  `previous_response_id`.
- **`previous_response_id`** — sticky-routing token replayed within a
  turn (sets `x-codex-turn-state` plus this body field). Never replayed
  across turns.
- **`tools`** — always serialized, even when empty (upstream's
  `tools: Vec<Value>` is non-skippable). Each tool entry follows
  Responses API tool shape with `type: "function"`. `output_schema` is a
  sibling of `parameters` (see §10).
- **`max_output_tokens`** — optional cap. When the server enforces it
  and reports `incomplete_details.reason == "max_output_tokens"`, the
  classifier treats it as a soft success (see §5).
- **`reasoning`** — `Option<Reasoning>` in upstream, but with NO
  `skip_serializing_if`. codex-swift mirrors this exactly: when neither
  `reasoningEffort` nor `reasoningSummary` is set, the body still
  contains `"reasoning": null` rather than omitting the key. This keeps
  the wire bytes byte-equivalent to serde output.
- **`include`** — defaults to `["reasoning.encrypted_content"]` when
  reasoning is active, `[]` otherwise.
- **`service_tier`** — optional; e.g. `"auto"`, `"flex"`.
- **`text`** — optional. When `textVerbosity` is set we emit
  `{ "verbosity": "low" | "medium" | "high" }`. JSON-schema output via
  `text.format` is intentionally not routed here yet — codex-swift uses
  per-tool `output_schema` instead (see §10).
- **`client_metadata`** — only emitted when non-empty (matches upstream
  `skip_serializing_if = Option::is_none`). See §12.

## 3. `store` and `previous_response_id` coupling

OpenAI requires the prior response to have been **stored** (i.e. the
prior request had `store: true`) before it can be referenced via
`previous_response_id`. Sending `store: false` + `previous_response_id`
yields HTTP 400 with `previous_response_not_found`.

Upstream Rust defaults `store: false` because its REST path doesn't
chain via `previous_response_id` — it relies on `prompt_cache_key` plus
full transcript replay. codex-swift's turn loop **does** chain
(`previousResponseId` is set for sticky routing within a turn), so the
default must be different.

codex-swift's defaults and coupling:

1. `ModelSettings.store` defaults to `true` (the public initializer
   parameter is `store: Bool = true`).
2. In `buildRequestBody` the coupling is enforced regardless of caller
   intent:

   ```swift
   let effectiveStore = settings.previousResponseId != nil ? true : settings.store
   ```

   That is, whenever `previousResponseId` is non-nil the body always
   carries `store: true`, even if the caller set `store: false`.

Callers that explicitly want `store: false` for a one-shot un-chained
request simply leave `previousResponseId` nil. This is the contract.

This was caught during cat-scan verification: the original P6.1 work
matched upstream's `Reasoning::default()` but did not validate the
chained-request behaviour against the live Responses API. See
`/tmp/parity-fixes/FOLLOWUPS.md` ("P6.1 store=false breaks chaining").

## 4. SSE event stream

The three HTTP transports (`OpenAIResponsesClient`,
`URLSessionResponsesClient`) — and the WebSocket transport, which
forwards a near-identical event grammar — map the following SSE event
types:

| SSE `type`                       | Mapped to                                     |
| -------------------------------- | --------------------------------------------- |
| `response.created`               | `ResponseEvent.created`                       |
| `response.output_text.delta`     | `ResponseEvent.agentDelta(itemId, delta)`     |
| `response.output_item.done` (`item.type=="message"`) | `ResponseEvent.agentDone(itemId, text)` |
| `response.output_item.done` (`item.type=="function_call"`) | `ResponseEvent.toolCall(callId, name, argumentsJSON)` |
| `response.completed`             | `ResponseEvent.completed(responseId, totalTokens, endTurn: true, usage: UsageSnapshot)` + finish |
| `response.failed`                | throw classified `ModelError` (see §6)        |
| `response.incomplete` (`max_output_tokens`) | `ResponseEvent.completed` (soft-success, see §5) |
| `response.incomplete` (other)    | throw retryable `ModelError(.incomplete)`     |
| any other type                   | ignored                                       |

Top-level `{ "error": { ... } }` frames (errors emitted before any
`response.*` event) are mapped to a terminal non-retryable `ModelError`.

A frame with `data: [DONE]` is treated as the canonical stream
terminator and ignored.

If the stream closes with no `data:` frames at all, the transport
throws a non-retryable `ModelError("no SSE from OpenAI ...")` (HTTP
path) or `ModelError("no SSE from OpenAI", retryable: false)`
(URLSession path) so callers don't silently treat an empty body as
success.

## 5. `response.incomplete` soft-success

When `incomplete_details.reason == "max_output_tokens"`, the stream is
treated as **terminal success**: we yield `.completed` with the partial
usage breakdown and let the turn record what was produced.

The rationale is documented in STATUS.md (lines 624-629): the model
produced as much text as the caller budgeted for, and retrying with the
same budget would just loop. Token usage is captured for truncated
turns.

The classifier helper is `ModelClientErrorClassifier.incompleteIsTerminalSuccess(_:)`:

```swift
public static func incompleteIsTerminalSuccess(_ responseObj: [String: Any]?)
-> Bool {
    guard let details = responseObj?["incomplete_details"] as? [String: Any],
          let reason = details["reason"] as? String else { return false }
    return reason == "max_output_tokens"
}
```

All three HTTP/WS transports use the same pattern:

```swift
case "response.incomplete":
    let respIncomplete = obj["response"] as? [String: Any]
    if !ModelClientErrorClassifier.incompleteIsTerminalSuccess(respIncomplete) {
        cont.finish(throwing: ModelClientErrorClassifier
            .classifyIncomplete(respIncomplete))
        return
    }
    fallthrough           // proceed to response.completed path
case "response.completed":
    ...
```

Any other reason (`content_filter`, `stop_sequence`, …) is mapped via
`classifyIncomplete` to a retryable `ModelError` tagged
`CodexErrorCode.incomplete`. Upstream
`codex-rs/codex-api/src/sse/responses.rs:347-356` treats every
`incomplete` event as `ApiError::Stream(...)` and forwards to the retry
loop; codex-swift mirrors that with `retryable: true` for the
non-`max_output_tokens` case.

## 6. `response.failed` error classification

`response.failed` carries an `error.code` string that upstream maps to
typed `ApiError` variants. codex-swift mirrors that mapping in
`ModelClientErrorClassifier.classifyResponseFailed(_:)`:

| Upstream `error.code`                              | `CodexErrorCode`         | `retryable` | `httpStatus` | Notes |
| -------------------------------------------------- | ------------------------ | ----------- | ------------ | ----- |
| `context_length_exceeded`, `context_window_exceeded` | `.contextWindowExceeded` | `true`      | `400`        | Feeds the trim-and-retry loop (P6.3) |
| `insufficient_quota`, `quota_exceeded`             | `.quotaExceeded`         | `false`     | `429`        | Terminal |
| `usage_not_included`                               | `.usageNotIncluded`      | `false`     | `402`        | Terminal |
| `cyber_policy`                                     | `.cyberPolicy`           | `false`     | `400`        | Terminal; if message is empty we substitute the canonical "flagged for possible cybersecurity risk." |
| `invalid_prompt`                                   | `.invalidRequest`        | `false`     | `400`        | Terminal |
| `server_is_overloaded`, `slow_down`                | `.serverOverloaded`      | `true`      | `503`        | Retryable |
| `rate_limit_exceeded`                              | `.rateLimited`           | `true`      | `429`        | `retryAfter` parsed from message body via `parseRetryAfterFromMessage` |
| _(empty / missing code)_                           | `.unknown`               | `true`      | nil          | Default retryable; retryAfter sniffed from message |
| any other code                                     | `.unknown`               | `true`      | nil          | Upstream catch-all (`ApiError::Retryable`) |

The classifier is exhaustive in tests; new codes from upstream land via
the G5 schema gate and may be added to `CodexErrorCode` without breaking
existing callers (the default `.unknown` keeps behaviour stable).

`parseRetryAfterFromMessage` recognises `try again in N s` / `try again
in N ms` snippets that the rate-limit body sometimes embeds — same
behaviour as upstream `try_parse_retry_after`. The HTTP `Retry-After`
header is parsed separately in §8/§9.

## 7. WebSocket transport

`WebSocketResponsesClient` speaks Responses-over-WebSocket against
`wss://api.openai.com/v1/responses` (or a UDS-WebSocket equivalent on
remote-execution paths). It is the production low-latency macOS data
path and the WS half of the transport-fallback wrapper.

### Handshake / headers

```
GET /v1/responses HTTP/1.1
Authorization: Bearer sk-...
OpenAI-Beta: responses_websockets=2026-02-06
Accept-Encoding: identity        // explicit no-zstd by default
x-codex-turn-state: <opaque>     // when settings.turnState is set
x-oai-attestation: <token>       // when attestationProvider returned non-nil
```

`Options.explicitNoZstd` (default `true`) sets `Accept-Encoding:
identity` so we never negotiate zstd compression — the WebSocket framing
is JSON-text and zstd would force codec churn for marginal benefit.

`OpenAI-Beta: responses_websockets=2026-02-06` opts into the v2 beta
handshake.

The attestation header is supplied by an `AttestationProvider` closure:
`@Sendable (_ threadId: String) async -> String?`. The supervisor wires
this to the broker so attestation tokens stay short-lived.

### Request envelope

The HTTP request body becomes a WebSocket text frame after two
transforms applied by `websocketCreateEvent(from:)`:

1. Add `"type": "response.create"`.
2. Remove `"stream"` and `"background"` (transport-level fields with no
   meaning over WS).

The resulting frame is JSON with **sorted keys** (`JSONSerialization`
`.sortedKeys`) so prewarm and main request hash-match byte-for-byte
when comparing client-side fixtures.

### Prewarm

When `Options.prewarm = true`, the client sends a prewarm frame first
(`requestEvent` plus `"generate": false`), suppresses its events, then
sends the real request. This warms the server's prompt cache before the
generating request is even sent. The two frames are dispatched
sequentially over the same WebSocket so the session-sticky behaviour
holds.

### Session-sticky WS→HTTPS fallback

`TransportFallbackModelClient` wraps a `(primary: WS, fallback: HTTPS)`
pair. On a retryable `ModelError` or mid-stream `CancellationError` it:

1. Retries the WS path up to `Limits.streamMaxRetries` (with full-jitter
   `Backoff` and a per-session retry `TokenBucket`).
2. After the retry budget is exhausted, engages the HTTPS fallback
   **for the rest of the session** (`fallbackEngaged = true`). The flag
   is sticky — once HTTPS is engaged the client does not try WS again on
   the same `TransportFallbackModelClient` instance.
3. Resets `attempts = 0` after engagement so HTTPS gets its own retry
   budget.

The wrapper is unique in observing failures **inside** the consumed
event stream (a dropped WS after the request has opened): the for-loop
inside `pump(...)` catches the error from `try await response.events`
and re-routes through retry / fallback.

## 8. URLSession transport

`URLSessionResponsesClient` (`#if os(macOS)`) is the native production
SSE path. It calls `URLSession.bytes(for:)`, validates the HTTP
response, then reads bytes into an SSE line buffer.

Key behaviours:

- **Error-body propagation**: when the HTTP response is non-2xx, the
  transport reads up to 4096 bytes of the body, prefixes the diagnostic
  with `[catscan] OpenAI HTTP <code> body: <body>`, writes it to stderr,
  and throws

  ```swift
  ModelError("OpenAI HTTP \(code): \(bodyStr)",
             retryable: code == 429 || code >= 500,
             httpStatus: code,
             retryAfter: retryAfterDuration(from: response))
  ```

  This is the agent diagnostic fix called out in FOLLOWUPS.md
  (post-DAG): previously the diagnostic was lost as `"OpenAI HTTP 400"`,
  which made `previous_response_not_found` invisible. Now the actual
  server body lands in `ModelError.message`.

- **`Retry-After` parsing**: `retryAfterDuration(from:)` parses the
  header in three forms — bare seconds (`"30"`), milliseconds via
  upstream's `"N ms"` convention, and HTTP-date (`"Fri, 03 Apr 2026
  12:00:00 GMT"`). The seconds-since-now diff is taken with
  `Swift.max(0, ...)`.

- **Cancellation**: `cont.onTermination = { _ in task.cancel(); session
  .invalidateAndCancel() }` so a consumer-dropped stream tears down the
  HTTP request immediately. The bytes-loop checks `Task.isCancelled`
  on each iteration and surfaces it as a clean `cont.finish()` rather
  than a thrown `CancellationError`.

- **Rate-limit telemetry**: HTTP headers are scraped via
  `RateLimitSnapshot.parseRateLimits(headerDump:)` and forwarded to the
  optional `UsageTracker`.

## 9. Retry strategy

Two layers sit between the engine and the transport:

### `RetryingModelClient`

Wraps a primary `ModelClient` and an optional fallback. On a
`ModelError.retryable == true`:

1. Increment `attempt`; reject if `attempt > limits.streamMaxRetries`.
2. Take a token from a per-session `TokenBucket` (capacity
   `retryTokensCapacity`, refill `retryTokensPerSecond`). This is the
   retry-amplification guard from hardening §6.
3. Sleep using either `error.retryAfter` (clamped to
   `limits.retryMaxDelay`) or the full-jitter `Backoff(base:
   limits.retryBaseDelay, maxDelay: limits.retryMaxDelay)`.
4. After exhaustion: engage the one-shot `fallback` exactly once.

### `TransportFallbackModelClient`

Session-sticky WS→HTTPS fallback, described in §7. Lives outside
`RetryingModelClient` so the WS retry budget is independent of the HTTPS
retry budget.

### Classification feeds retry

`ModelError.retryable` is set by:

- the HTTP-level path (status 429 / 5xx are retryable, the rest aren't),
- the SSE classifier (see §6 table),
- the `URLSession` catch-all (network failures default to retryable).

`retryAfter` is set from:

- HTTP `Retry-After` (URLSession path),
- the message body's `try again in N s/ms` pattern (SSE classifier).

## 10. `output_schema` plumbing

Each `ToolSpec` carries an optional `outputSchemaJSON: String?` — a
JSON-Schema object describing the tool's structured output. When set,
codex-swift emits it as a sibling of `parameters` on the per-tool
Responses API entry:

```json
{ "type": "function",
  "name": "memory_get",
  "description": "Read a key from durable memory.",
  "parameters": { "type": "object", "properties": { "key": { "type": "string" } } },
  "output_schema": { "type": "object", "properties": { "value": { "type": "string" } } } }
```

The deliberate divergence from upstream is documented in the `ToolSpec`
doc comment in `ModelClient.swift`:

> upstream marks the field `#[serde(skip)]` in its REST path and instead
> routes structured-output enforcement through the prompt-level
> `text.format` field; we keep the per-tool emission both for code-mode
> parity and so structured output is genuinely declared on the wire when
> the provider honours it.

This was reactivated in P4.8 / H-32 follow-up work — see
FOLLOWUPS.md "From REV P4.8" → `output_schema` not plumbed.

## 11. Reasoning token breakdown (P2.2 / H-05)

Reasoning models surface a per-call token breakdown in
`usage.output_tokens_details.reasoning_tokens`. All three transports
extract it and pack it into a `UsageSnapshot`:

```swift
let outputDetails = usage?["output_tokens_details"] as? [String: Any]
let snap = UsageSnapshot(
    inputTokens:        intOf(usage?["input_tokens"]),
    cachedInputTokens:  intOf(details?["cached_tokens"]),
    outputTokens:       intOf(usage?["output_tokens"]),
    reasoningOutputTokens: intOf(outputDetails?["reasoning_tokens"]),
    totalTokens:        intOf(usage?["total_tokens"]))
```

`UsageSnapshot` (in `Sources/ModelClient/ModelProvider.swift`) carries
the full 5-field breakdown so the per-call delta reported to the
supervisor — and then to the client via `thread/tokenUsage/updated` —
matches upstream `TokenUsage` byte-for-byte. Providers that don't
surface the breakdown leave `reasoningOutputTokens: 0`.

## 12. `client_metadata`

Per upstream `build_responses_request` (`client.rs:760-763`), the REST
body's `client_metadata` field carries **only** the installation id:

- `x-codex-installation-id` — UUID written to
  `<codexHome>/installation_id` (`CodexClientIdentity.resolveInstallationId`).
  Same constant name as upstream's `X_CODEX_INSTALLATION_ID_HEADER`.

Upstream also tracks `cliVersion` and `originator`, but **not in the
REST body**:

- `cli_version` appears in rollout `session_meta` (telemetry).
- `originator` is a separate string used for tagging requests
  (`build_ws_client_metadata` for the WebSocket path).

codex-swift mirrors this exactly. `CodexClientIdentity.cliVersion`
(`"0.1.0"`) and `CodexClientIdentity.originator`
(`"codex-swift/0.1.0"`) are NOT injected into `client_metadata` — they
land in rollout / telemetry surfaces only.

The body builder honours whatever is in `settings.clientMetadata`
verbatim. When the map is empty, the field is omitted entirely (upstream
`#[serde(skip_serializing_if = Option::is_none)]` on `common.rs:188`).
Callers that have the installation id pass it via:

```swift
var settings = ModelSettings(model: "gpt-5.1-codex", threadId: "thr_a")
if let installationId = CodexClientIdentity.resolveInstallationId(
    codexHome: codexHome) {
    settings.clientMetadata[CodexClientIdentity.installationIdKey] = installationId
}
```

## 13. Mock client

`MockModelClient` (an `actor` conforming to `ModelClient`) replays a
scripted `MockScenario` deterministically. Each scenario is a sequence
of `MockStep`s:

```swift
public enum MockStep: Sendable, Equatable {
    case created
    case delta(itemId: String, String)
    case agentDone(itemId: String, String)
    case toolCall(callId: String, name: String, argumentsJSON: String)
    case completeEndTurn(responseId: String, tokens: Int)
    case completeContinue(responseId: String, tokens: Int)
    case failRetryable(String)
    case failTerminal(String)
    case failContextWindow(String)   // simulates context_window_exceeded
    case slowMillis(Int)
}
```

Helpers ship with the type:

- `MockScenario.hello(_:)` — a single assistant message then end-turn.
- `MockScenario.toolLoopCompactionSequence(repetitions:)` — drives the
  auto-compaction ladder by yielding high-token-count
  `.completeContinue`s; used by the wire-faithful replay tests.

Use in unit tests:

```swift
let mock = MockModelClient(scenarios: [.hello("Hi!")])
let stream = try await mock.stream(prompt, settings)
for try await event in stream.events {
    // assert event sequence
}
```

`CapturedRequest` (also in `MockModelClient.swift`) records what the
engine sent — used by tests that need to assert on the request body
bytes without actually hitting the network. `RecordingModelClient` is
the lighter observer wrapper around an existing `ModelClient` for
spies.

## 14. Pointers

- `Sources/ModelClient/ModelClient.swift` — protocol, `Prompt`,
  `ModelSettings`, `ResponseEvent`, error classification, default
  values.
- `Sources/ModelClient/OpenAIResponsesClient.swift` — curl-backed
  portable SSE; owns `buildRequestBody`.
- `Sources/ModelClient/URLSessionResponsesClient.swift` — macOS native
  SSE.
- `Sources/ModelClient/WebSocketResponsesClient.swift` — Responses-over-
  WebSocket (prewarm + attestation + no-zstd).
- `Sources/ModelClient/TransportFallbackModelClient.swift` —
  session-sticky WS→HTTPS fallback.
- `Sources/ModelClient/RetryingModelClient.swift` — bounded retry
  wrapper.
- `Sources/ModelClient/AuthRefreshingModelClient.swift` — 401-refresh
  decorator.
- `Sources/ModelClient/MockModelClient.swift` — scripted mock.
- `Sources/ModelClient/RecordingModelClient.swift` — observing wrapper.
- `Sources/ModelClient/StreamMapper.swift` — bounded stream + consumer
  cancel.
- `Sources/ModelClient/ModelProvider.swift` — provider registry,
  `UsageSnapshot`, `RateLimitSnapshot`, `UsageTracker`.
- `STATUS.md` (lines 624-629) — the `max_output_tokens` soft-success
  invariant.
- `/tmp/parity-fixes/FOLLOWUPS.md` — cat-scan fixes:
  `store=true` default, `previousResponseId` coupling,
  `output_schema` plumbing, HTTP-body propagation in URLSession.
- Upstream Rust source pinned in `codex-rs/codex-api/src/common.rs`
  (`ResponsesApiRequest`), `codex-rs/core/src/client.rs`
  (`build_responses_request`), and `codex-rs/codex-api/src/sse/responses.rs`
  (`process_responses_event`).
