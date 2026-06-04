# Media Generation

*Ask the agent to make an image (and, later, video / music / speech) without blocking the turn — the job runs async, the asset is written under a media root, and the result is delivered to you.*

## Why it matters

Generative media is *slow* — seconds to minutes. If a turn blocked while an image rendered, the whole session would stall. So media generation has to be a fire-and-forget job: the agent asks for it, gets a task id back immediately, and the result shows up later — surviving a daemon restart in between. And because a finished asset is something you want *pushed* to you (not left as a file path you have to go find), media leans on the same delivery primitive as everything else.

## What it is

An async media-task suite:

- **A `media_generate` tool** the agent calls with `{ kind, prompt, deliver_to?, idempotency_key? }`. It returns a `task_id` immediately. `kind` is `image` / `video` / `music` / `speech`.
- **A ledger** that tracks each task through `queued → running → done/failed`, dedups by idempotency key, and persists to disk so queued work survives a crash.
- **A provider** that does the actual generation. The MVP ships a deny-default **stub** provider (an inline placeholder, useful for wiring + tests); a real async backend (OpenAI Images / fal) is a documented next step.
- **Delivery** of the finished asset to an optional `deliver_to` push target, via the same durable, SSRF-screened `PushRouter`.

## How it works

**The ledger lifecycle (`MediaTaskLedger`).** `submit` either completes inline (a fast/stub provider) or persists a `.queued` task and returns its id. A daemon-resident **`MediaPoller`** loops `advance()`, polling each queued task's provider until it reaches `done`, then delivering it. Delivery is **decoupled from terminal status**: a `.done` task whose push fails is *retried* on later passes (bounded by `deliveryAttempts`, max 10), so a transient push failure never silently drops a finished asset. Terminal tasks are pruned beyond a retention cap so the ledger doesn't grow without bound. The ledger persists to a durable JSON file (atomic writes) and recovers queued tasks on restart.

**Approval only when delivering.** Generating-and-holding an asset is ungated; *delivering* it to a push target is the outbound action, so `media_generate` requires approval only when `deliver_to` is set. An empty/whitespace `deliver_to` is normalized to "no target" *before* that decision, so a blank value can't slip through as an ungated-but-broken delivery.

**Worker-mode asymmetry (enforced, not hidden).** The daemon poller can only drive a ledger in its *own* process. Under the default **spawned** worker mode, each worker holds its own ledger — fine for the inline stub (it delivers synchronously, no poller needed), but an *async* provider's queued tasks would wedge with no poller to drive them. So `MediaWiring` **fails closed**: an async provider configured without in-process workers (`CODEXKIT_IN_PROCESS_WORKERS=1`) is refused with a loud warning, and the tool self-prunes rather than accept jobs it can't finish.

**Untrusted inbound media** (a future `pdf_read` / `transcribe`) is decoded in the [sandboxed media-decode helper](../../ADDONS.md) (`codex-mediadecode`), never in-process — decompression bombs and malformed files are contained in a short-lived, rlimited, no-network child.

## Using it

**Enable it.** Deny-default. Turn it on with `[features].media = true` (or `CODEX_FEATURE_MEDIA=1`):

```toml
[features]
media = true

[media]
provider = "stub"              # MVP; an async provider needs in-process workers + api_key_env
media_root = "$CODEX_HOME/media"
# api_key_env = "OPENAI_API_KEY"   # required for a non-stub provider
```

With it on, the agent can call `media_generate`. A generate-and-hold call returns a `task_id` and an asset path under `media_root`; a `deliver_to` call pauses for your approval, then pushes the finished asset's location to that target (e.g. `ntfy:art`). Delivery currently sends the local asset path; a signed `MediaToken` URL served by the WebGateway (sharing its signer + media root) is a documented follow-on.

## What it enables

- **Media without stalling.** The turn keeps moving; the render arrives when it's ready.
- **Crash-safe long jobs.** A queued task survives a daemon restart and the poller keeps driving it — the same durability discipline as push and cron.
- **One delivery path.** Finished assets land on your phone through the same screened, durable `PushRouter`.

## Status

**Built, tested, and wired (stub MVP).** The `Media` module (`MediaTaskLedger` submit/poll lifecycle, idempotency dedup, decoupled-and-bounded delivery retry, `FileMediaStore` durable atomic store, `MediaPoller`, `MediaConfig`, the deny-default `StubMediaProvider` + factory, `MediaWiring`), the approval-gated `media_generate` tool, and the codexd/codex-session wiring (in-process eager ledger + poller, spawned-worker self-prune for async providers) are all live. Severe tests cover config deny-default + key gating + `$CODEX_HOME` expansion + the `CODEX_FEATURE_MEDIA` env, the stub write-under-root, file-store round-trip + crash recovery, the poller driving a recovered queued task to done+delivered, transient-delivery retry + bound, the empty-`deliver_to` ungated-and-not-pushed normalization, bounded terminal-task retention, and the async-provider-in-spawned-mode refusal. **Next:** a live async provider (OpenAI Images / fal), signed-URL delivery sharing the gateway signer, and the `pdf_read`/`transcribe` inbound tools over the sandboxed decoder.

## Go deeper

Source: `Sources/Media/` (ledger, poller, config, provider, wiring, store), `Sources/MediaDecode/` + `Sources/codex-mediadecode/` (sandboxed inbound decode). Design: [ADDONS.md](../../ADDONS.md) section "8. Async media suite". Delivery rides the [push](push.md) primitive; the sandboxed decoder is the [security](../guides/security.md) seam for untrusted media.
