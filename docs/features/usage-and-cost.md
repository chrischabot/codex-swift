# Token Usage & Cost

*How codex-swift counts tokens, tracks per-turn usage, and turns that into a dollar figure — so you always know what a session is spending.*

## Why it matters

Every agent turn sends a growing transcript to the model and gets tokens back, and you pay for both. In a long coding session the input side balloons fast — but most of it is *cached* prompt that the provider bills at roughly a tenth of the fresh rate. If you account for tokens naively (full input price for everything) your cost estimate can be off by ~7x, because in real agent runs 97-98% of input tokens are cache hits.

You are running a benchmark suite, or just a long session, and you want to answer two questions: "how close am I to the context window before auto-compaction kicks in?" and "what did that run actually cost?" codex-swift answers both from the same usage stream the model already reports — no guesswork, no separate metering service.

## What it is

A small, layered accounting system that:

- **Counts tokens** for any piece of text (used to budget context and trigger auto-compaction), either with a fast byte approximation or a real BPE tokenizer.
- **Knows each model's shape** — context window, max output, auto-compact trigger — via a read-only model catalog.
- **Tracks real usage per turn** by parsing the `usage` object the OpenAI Responses API returns: input, cached-input, output, and reasoning-output tokens, plus a running session total.
- **Prices it** with a built-in per-model rate table that charges cached input at the discounted rate.

The result surfaces as a live `thread/tokenUsage/updated` notification, as `token_count` records in the session rollout, and as a cost column in the benchmark report.

## How it works

Four pieces cooperate:

**1. Token counting (`Sources/Tokenizer`).** The default `ApproxTokenCounter` returns `ceil(utf8_bytes / 4)` — byte-for-byte faithful to Codex's `approx_token_count`, which is what the auto-compact ladder and skills budget rely on. A real `BPETokenizer` (the GPT-2 / tiktoken algorithm) is available but opt-in: drop the OpenAI merge table at `$CODEX_HOME/tokenizer/<name>.json` and `TokenCounting.resolve(...)` will use it; with no table on disk it falls back to the approximation so parity is preserved.

**2. Model catalog (`Sources/Tokenizer/ModelCatalog.swift`).** Each `ModelEntry` carries `contextWindow`, `maxOutputTokens`, `effectiveContextPercent` (default 95), and a `tokenizerName`. Resolution uses longest-matching-prefix (so `gpt-5.5` beats `gpt-5`), and unknown slugs get a 272k fallback descriptor. The catalog also computes the auto-compaction *trigger*: `autoCompactTokenLimit = (contextWindow * 9) / 10` — a hard 90% of the window — optionally min'd with a user-configured `model_auto_compact_token_limit`.

**3. Per-turn accounting (`Sources/ModelClient` + `Sources/HarnessCore`).** When a `response.completed` SSE frame arrives, the transport reads the provider's `usage` object into a `UsageSnapshot`:

```
input_tokens                          -> inputTokens
input_tokens_details.cached_tokens    -> cachedInputTokens
output_tokens                         -> outputTokens
output_tokens_details.reasoning_tokens-> reasoningOutputTokens
total_tokens                          -> totalTokens
```

The `SessionEngine` treats that as the **last** bucket (this call's delta) and `addAssign`s it into the session-cumulative **total** bucket (`TokenUsageBucket`), mirroring upstream `TokenUsageInfo::append_last_usage`. Separately, the `ContextManager` keeps a gauge for compaction: `totalTokenUsage()` = last server-reported total + a local byte estimate of items recorded since the last model item. That gauge — not the raw usage sum — is what gets compared against the auto-compact limit.

```
SSE response.completed.usage
        |
        v
   UsageSnapshot (5 fields)
        |
   last bucket --addAssign--> cumulative total bucket
        |                          |
        v                          v
 token_count rollout       thread/tokenUsage/updated  (total + last + modelContextWindow)
        |
        v
 RolloutAnalyzer / Pricing -> $ cost
```

**4. Pricing (`Sources/BenchKit/Pricing.swift`).** A static `[prefix -> Rate]` table in USD per 1M tokens, with separate `inp`, `cached`, and `out` rates per model family. `Pricing.cost(...)` bills the cached subset at the cache rate and the remaining fresh input at the full rate:

```
cost = fresh/1e6 * inp  +  cached/1e6 * cached_rate  +  output/1e6 * out
```

Unknown models cost `0`. Note this lives in BenchKit and is consumed by the benchmark harness — it is *not* a live in-session spend meter.

## Using it

**See live usage in a session.** The `SessionEngine` emits a `thread/tokenUsage/updated` v2 notification after every inference call. Its payload is `{ total, last, modelContextWindow }`, each bucket carrying the five-field breakdown (`inputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningOutputTokens`, `totalTokens`). A client renders the context gauge from `total.totalTokens / modelContextWindow`. The same numbers are persisted as `token_count` records in the session rollout file, so they survive after the run.

**Get a cost number in benchmarks.** `Pricing.cost(model:inputTokens:cachedInputTokens:outputTokens:)` is called by `CodexSwiftSession` once a task's `total` bucket is collected:

```swift
info.costUSD = Pricing.cost(model: model,
                            inputTokens: acc.inTok,
                            cachedInputTokens: acc.cachedTok,
                            outputTokens: acc.outTok)
```

The bench report (`Reporter.swift`) then prints an `Avg cost` summary column and a per-task `cost` column, e.g. `$0.04`. `RolloutAnalyzer` reads the persisted `agentInfo` / `token_count` records back out and renders a table with `cost`, model `calls`, and a `cache` hit-percentage column (`cachedInputTokens * 100 / inputTokens`).

**Current rate table** (USD per 1M tokens, `inp` / `cached` / `out`):

| Model prefix | Input | Cached | Output |
|---|---|---|---|
| `gpt-5.5` | 1.25 | 0.125 | 10.0 |
| `gpt-5.4-mini` | 0.25 | 0.025 | 2.0 |
| `gpt-5.4` / `gpt-5` | 1.25 | 0.125 | 10.0 |
| `gpt-4o-mini` | 0.15 | 0.075 | 0.60 |
| `gpt-4o` | 2.50 | 1.25 | 10.0 |
| `o3` | 2.0 | 0.50 | 8.0 |
| `o4-mini` | 1.10 | 0.275 | 4.40 |
| `gpt-realtime-2` / `gpt-realtime` | 4.0 | 0.40 | 24.0 (text only) |

**Use a real tokenizer (optional).** If you need exact token ids rather than the byte approximation, place the OpenAI table (`{"encoder": {...}, "merges": [...]}`) at `$CODEX_HOME/tokenizer/o200k_base.json`. `TokenCounting.resolve(codexHome:tokenizerName:)` picks it up automatically; otherwise nothing changes and the approximation is used.

## What it enables

- **Auto-compaction** — the context gauge from `ContextManager.totalTokenUsage()` vs `ModelCatalog.autoCompactLimit(...)` is what decides when history gets summarized, keeping long sessions inside the window.
- **Benchmark cost reporting** — `Avg cost`, per-task cost, and cache-hit percentage in the [DeepSWE benchmark runner](../benchmarks/DEEP_SWE_RUNNER.md), so model/config comparisons are spend-aware.
- **Rate-limit and credits telemetry** — the same response headers also carry `x-codex-credits-*` and rate-limit windows, parsed into a `RateLimitSnapshot` and forwarded as `account/rateLimits/updated`, giving operators a quota view alongside token usage.
- Composes with the [Model Client](../MODEL_CLIENT.md) (where `usage` is parsed) and the [Protocol](PROTOCOL.md) layer (which defines the `thread/tokenUsage/updated` wire shape and `token_count` rollout record).

## Status

The dollar-cost path (`Pricing`) is a BenchKit feature for the benchmark report, not a live in-session billing meter. The rate table is approximate and hand-maintained; unknown models price to `0`. Realtime voice models are priced on **text** tokens only — audio and image input tokens are not modeled. The BPE tokenizer is off by default (the byte approximation is the parity-preserving default).

## Go deeper

Internals and wire fidelity: `Sources/ModelClient/ModelProvider.swift` (`UsageSnapshot`, header parsing), `Sources/HarnessCore/ContextManager.swift` (the compaction gauge), and `docs/MODEL_CLIENT.md`.
