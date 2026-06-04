# Push & Outbound Delivery

*Let the agent reach **you** — a phone notification when a long job finishes, a webhook into your own systems — through one durable, SSRF-screened delivery primitive, with the owner path and the model path kept distinct.*

## Why it matters

A request-response agent goes quiet the moment your turn ends. The capabilities that make an assistant feel *alive* are the proactive ones: "ping my phone when the deploy is green," "post the nightly summary to this webhook." That means the agent — or a scheduler firing on its behalf — must be able to send a message *outbound*, to a destination you chose, reliably enough that a crash between "done" and "sent" doesn't silently drop it.

Two things make this dangerous if done naively. First, an outbound HTTP call chosen by a model is an **SSRF primitive** — point it at `http://169.254.169.254/` and it reads your cloud credentials. Second, "the agent can notify me" and "anyone who can reach the agent can make it notify *anywhere*" must not be the same capability. Push is the primitive that makes proactive delivery durable, SSRF-screened, and correctly gated.

## What it is

A durable outbound message router with two delivery sinks and two callers:

- **Sinks** — `ntfy` (zero-signup push to your phone via [ntfy.sh](https://ntfy.sh) or a self-hosted server) and `webhook` (an HTTPS POST to a URL you control). Both sit behind the [egress chokepoint](../guides/security.md#egress-chokepoint-ssrf-defense).
- **The model path** — a `push_send` tool the agent can call mid-turn. It is **approval-gated** (the owner consents before an outbound send) and can be restricted to an allowlist of targets.
- **The owner path** — an `outbound/send` JSON-RPC method and a `codex-send` CLI. This is the *trusted* path: no approval prompt, but reachable only over an owner-local transport (stdio / Unix socket), never the browser.

Targets are written `"<scheme>:<rest>"` — `ntfy:my-topic` or `webhook:https://hooks.example/path`.

## How it works

**Durability (`DeliveryCore`).** Every send is a job in a `DurableDeliveryQueue` backed by an append-only JSONL log. Each state transition (`enqueued → send_attempt_started → {acked | unknown_after_send | failed}`) is fsync'd *before* the side effect, so a crash mid-send is recoverable: `recover()` re-drives non-terminal jobs in order. Delivery is **at-least-once**; pass an `idempotency_key` for crash-safe dedup (a keyless send is at-least-once *without* dedup — a duplicate on a rare crash-mid-delivery is possible). Transient failures (5xx, transport) retry with backoff; permanent ones (4xx, an egress denial) are not retried.

**SSRF containment.** Both sinks `vet()` the target URL through `EgressGuard` before any connect: HTTPS-only, optional host allowlist, and a block on loopback / RFC1918 / link-local (incl. metadata `169.254.169.254`) / CGNAT / v4-in-v6, with strict numeric-host parsing so `https://0x7f.1/` can't sneak through. An ntfy topic is whitelisted to a single safe path segment so it can't smuggle a path or host. The deny *reason* is never surfaced to the RPC caller (it would leak internal resolver/host info) — only `ok` plus a generic detail.

**The owner boundary is the transport.** codex-swift has no per-RPC owner token. The daemon-level `RequestRouter` (stdio / Unix socket / loopback) is owner-trusted; the per-tab WebGateway routers are a lower trust tier. The `outbound/send` arm refuses unless the router was built with `allowsOwnerOnlyRPC: true` — which the daemon router is and the WebGateway router factory deliberately is not. A process-global `PushRouterHolder` publishes the one daemon-scope router so the RPC handler (and the cron/media delivery paths) reach it; an unconfigured daemon leaves it nil and the method replies "push feature is not enabled."

```
  model path:  push_send tool ──approval──┐
                                          ├─► PushRouter ──► EgressGuard ──► ntfy / webhook sink
  owner path:  outbound/send RPC ─owner-gated┘   (durable queue, retry, dedup)
               codex-send CLI ──► spawns codexd over stdio ──► outbound/send
```

## Using it

**Enable it.** Push is deny-default. Turn it on with `[features].push = true` (or `CODEX_FEATURE_PUSH=1`). When on, `codexd` builds the durable router and advertises `push_send` to sessions.

```toml
[features]
push = true
```

**Send from the CLI (owner path):**

```bash
codex-send ntfy:my-test-topic 'deploy finished ✅'
codex-send webhook:https://hooks.example/notify 'nightly summary ready' --idempotency-key run-42
```

`codex-send` spawns an isolated, stdio-only `codexd` (it strips `CODEXKIT_LISTEN`/`_WEB`/`_MEMORY` so it never fights a running daemon for a socket, port, or lock, and forwards `CODEX_FEATURE_PUSH`), issues `initialize → outbound/send`, prints the result, and reaps the child. Exit 0 on delivery, non-zero otherwise. Set `CODEXD_BIN` to point at a specific `codexd`.

**Send from the model (tool path).** With push enabled, the agent can call `push_send` — but every send pauses for your approval first, and an operator allowlist (`allowedTargets`) can restrict it to known destinations.

**As a building block.** The [cron scheduler](cron.md) and [media suite](media.md) deliver their results through this same `PushRouter` (via `PushRouterHolder`), so a scheduled job's output or a finished render lands on your phone through the one screened, durable path.

## What it enables

- **A proactive agent.** "Tell me when it's done" stops being a thing you have to sit and wait for.
- **Integration into your own systems.** A webhook target turns any agent or scheduled job into an event source for whatever you've already built.
- **One screened egress for every outbound feature.** Push, cron delivery, and media delivery all funnel through the same `EgressGuard` chokepoint and the same durable queue — SSRF is contained in one place, durability is solved once.

## Status

**Built, tested, and wired.** The `Push` module (`PushTarget`, `NtfySink`/`WebhookSink` behind `EgressGuard`, `SinkRegistry`/`PushRouter` over `DurableDeliveryQueue`, the approval-gated `push_send` tool), the `outbound/send` RPC (owner-gated via `allowsOwnerOnlyRPC`, deny-default, deny-reason not leaked), and the `codex-send` CLI are all live. Severe tests cover the owner gate (web tier refused, daemon serves), deny-default, SSRF metadata/IPv6/decimal-int targets (zero POSTs, no reason leak), HTTP-scheme rejection, oversize bounds, idempotency dedup, and pre-initialize lockout. **Residual:** full connect-time IP pinning vs. DNS-rebinding needs a socket-level HTTP client (`URLSession` can't pre-pin); redirects-off + egress-vet + permanent-deny are the current defenses, documented in `PushSinks.swift`.

## Go deeper

Source: `Sources/Push/` (router, sinks, tool, holder), `Sources/DeliveryCore/DeliveryCore.swift` (durable queue), `Sources/EgressGuard/EgressGuard.swift` (SSRF screen), `Sources/codex-send/main.swift` (CLI). Design + the adversarial security review: [ADDONS.md](../../ADDONS.md) section "7. Push / outbound". The owner-boundary model is in [security.md](../guides/security.md).
