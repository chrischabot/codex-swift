# Observability

*See what the daemon is doing while it runs: structured logs, Instruments-grade timing spans, a non-blocking metrics ring, and a push exporter that ships those metrics to any OpenTelemetry collector.*

## Why it matters

The daemon runs unattended. It builds prompts, samples models, runs tools, compacts context, ingests memory documents, and serves the web gateway — often for hours, across multiple sessions, with no human watching. When a turn hangs, a tool gets slow, or memory ingestion silently stalls, you need to answer two questions fast: *what is it doing right now*, and *what was it doing just before it broke*.

Picture a user filing a bug: "the agent froze for 30 seconds mid-task." Without instrumentation you are guessing. With it you open Instruments, see the `turn` timeline, and watch a single `mem.process` span balloon — or you query your OTel dashboard and see `mem.brain.calls` latency spike on one model. The same plumbing also captures the recent log tail so a user-submitted feedback bundle ships the exact lines leading up to the freeze.

Observability is the layer that makes the daemon legible — both live and after the fact — without ever slowing down the work it instruments.

## What it is

A small, dependency-light instrumentation kit (the `Observability` target) with four user-facing capabilities:

- **Structured logging** — a `Log` value with `debug`/`info`/`warn`/`error` levels and a subsystem/category. On Apple platforms it bridges to the OS unified logging system (`os.Logger`), so logs show up in Console.app and `log stream`; on Linux it writes JSON lines to stderr. Every log line is also mirrored into an in-memory ring (below).
- **Timing spans** — a `Span` you wrap around a phase of work (prompt build, sample, tool, compact, memory extract). On Apple platforms it emits a real `os_signpost` interval visible as a labeled region on the Instruments timeline; everywhere it records a duration metric.
- **A metrics sink** — `MetricsSink` records counts, durations, and gauges into a fixed-size overwrite ring that never blocks and never grows. This is the RED-style (Rate / Errors / Duration) plus saturation surface.
- **An OTLP exporter** — `OTLPMetricsExporter` drains the sink, serializes it to OpenTelemetry's OTLP/JSON wire format, and POSTs it to a collector you configure. Off by default (no-op sink) so the daemon never blocks on telemetry.

There is also a `FeedbackLogStore` — the in-memory log buffer that powers crash-context capture and user feedback uploads.

> Note on Prometheus: there is **no Prometheus exporter and no `/metrics` scrape endpoint** in the codebase today. Metrics egress is OTLP/JSON over HTTP only, and it is a *push* model (the daemon POSTs to a collector). If you run Prometheus, point an OpenTelemetry Collector at the daemon's OTLP endpoint and let the collector do the Prometheus exposition.

## How it works

Three independent paths, all designed so telemetry can never back-pressure real work.

**Logs.** `Log.log(level:)` filters by `minLevel`, then does two things: records a `FeedbackLogEntry` into `FeedbackLogStore.shared`, and emits to `os.Logger` (Apple) or stderr JSON (Linux). The feedback store is a capacity-bounded ring (default 4096 entries) that drops the oldest line when full and counts the drops.

**Spans.** `Span` is a `~Copyable` value. Its initializer stamps a start time and (on macOS 12+/iOS 15+) calls `OSSignposter.beginInterval`; its `deinit` computes the elapsed duration, records it on the `MetricsSink`, and calls `endInterval`. So a span is just a scoped variable — when it goes out of scope the interval closes automatically.

**Metrics → export.** `MetricsSink` wraps an `OverwriteRing<MetricPoint>` (the "C4" telemetry ring). `count`/`observeDuration`/`gauge` push tiny `Sendable` points; if the ring is full the oldest point is overwritten and `droppedCount` increments — the hot path is never stalled. A background task drains the ring on a cadence and hands the points to the exporter.

```
  work path                          export path (background, every 60s)
  ---------                          -----------------------------------
  Span/sink.count(...) ─push─▶ OverwriteRing ─drain─▶ OTLPMetricsExporter
       (never blocks)          (overwrite-oldest)          │ encode → OTLP/JSON
                                                            ▼
                                                   OTLPSink.send()
                                              (DisabledOTLPSink = no-op,
                                               or CurlOTLPSink → collector)
```

`OTLPMetricsExporter.encode` maps each point to one OTLP metric: `count` → a monotonic `Sum` (aggregation temporality `2`, `isMonotonic: true`); `duration` and `gauge` → a `Gauge`. The point's `tag` becomes an attribute (empty tag → no attributes). The whole document is wrapped in a `resourceMetrics` envelope carrying `service.name`. `drain()` clears the ring so the same points are never re-sent, and an empty batch is a no-op success. The collector endpoint is injected as an `OTLPSink`: the default `DisabledOTLPSink` returns success without doing anything, and `CurlOTLPSink` shells out to `curl` to POST `application/json` (portable across Linux/macOS, no URLSession dependency).

## Using it

**Emit a log** (in any module that imports `Observability`):

```swift
let log = Log(category: "codexd")          // subsystem defaults to "ai.igent.codexkit"
log.info("router accepted thread \(id)", threadId: id)
log.warn("retrying after transport error")
```

Pass `minLevel: .debug` to a `Log` to see debug lines; the default is `.info`. There is currently **no environment variable to change the level at runtime** — it is set in code at construction. The daemon constructs its logger as `Log(category: "codexd")`.

**View logs.** On macOS, stream the daemon's unified-logging output:

```bash
log stream --predicate 'subsystem == "ai.igent.codexkit"' --level debug
# or filter a span category:
log stream --predicate 'subsystem == "ai.igent.codexkit" && category == "turn"'
```

On Linux the daemon logs JSON lines to stderr — capture them however you run the process.

**Wrap a span:**

```swift
let span = Span("mem.process", tag: doc.sourceURI,
                sink: MemoryMetrics.sink, category: "com.codexkit.memory")
defer { _ = span }   // keep it alive for the scope; deinit closes the interval
```

To see spans live, open **Instruments → os_signpost** and filter on subsystem `ai.igent.codexkit` (or `com.codexkit.memory` for the memory pipeline). Each `Span` shows as a named interval on the timeline.

**Record a metric:**

```swift
MemoryMetrics.sink.count("turn.start", tag: threadId)
MemoryMetrics.sink.observeDuration("turn.dur", tag: threadId, seconds: elapsed)
MemoryMetrics.sink.gauge("queue.depth", tag: "c2", Double(depth))
```

**Turn on metrics export.** Set the collector endpoint and the daemon switches from the no-op sink to `CurlOTLPSink`:

```bash
export CODEXKIT_OTLP_ENDPOINT="http://localhost:4318/v1/metrics"
```

In `codex-memory`, this exact env var selects `CurlOTLPSink(endpoint:)`; otherwise it falls back to `DisabledOTLPSink`. A background task there drains `MemoryMetrics.sink` and exports it **every 60 seconds** under `service.name = "codex-memory"`. The memory pipeline emits a documented `mem.*` set: `mem.ingest.docs`, `mem.ingest.bytes`, `mem.chunks.created`, `mem.embeddings.created`, `mem.extract.tokens`, `mem.score.gate_pass`, `mem.brain.calls` / `mem.brain.tokens_in` / `mem.brain.tokens_out` / `mem.brain.cost_usd`, `mem.ring.dropped` (should stay zero — non-zero is an alert), and the `mem.store.wal_bytes` gauge.

**What you see at the collector:** an OTLP/JSON `resourceMetrics` payload, one metric per point, counts as monotonic sums and durations/gauges as gauges, with `tag` attributes. Point any OTel-compatible backend (Grafana/Tempo/Mimir, Honeycomb, a local Collector) at the endpoint.

**Feedback / crash context.** The `FeedbackLogStore` is what `feedback/*` RPCs read. `renderFeedbackLogs(threadIds:)` returns the recent log tail for a thread (threadless rows are always included), newest-first, bounded by byte caps (oversized single lines are skipped, default 1 MiB/line and 5 MiB total). The supervisor writes this into the `codex-logs.log` attachment of a feedback bundle under `$CODEX_HOME/feedback/`.

## What it enables

- **Live operator monitoring** — `log stream` and Instruments give you a real-time view of the daemon with zero added infrastructure.
- **Production dashboards & alerting** — flip one env var and metrics flow to your OTel stack; `mem.ring.dropped > 0` is a ready-made saturation alert.
- **Actionable bug reports** — the in-memory log ring rides along with [feedback uploads](../app-server-api.md) so reports arrive with the exact lines leading up to a failure.
- **Composability** — the same `MetricsSink`/`Span` primitives instrument the memory pipeline (see [Memory Wiki](../codex-swift-memory-wiki.md) §8) and are available to any module via `Observability`. Because the metrics ring is overwrite-oldest, instrumenting a new hot path is safe by construction.

## Status

- **OTLP/JSON metrics export** is implemented and unit-tested but **off by default** — no `CODEXKIT_OTLP_ENDPOINT` means a no-op sink.
- **Prometheus** is **not implemented** (no exporter, no scrape endpoint); use an OTel Collector to bridge to Prometheus.
- **Log level** is set in code (`minLevel`), not via a runtime flag/env var.
- `os_signpost` intervals require macOS 12+/iOS 15+; older OS versions and Linux keep the duration metric only.
- Only the `codex-memory` process wires up the periodic OTLP drain loop today; the primitives are general, but other daemons emit metrics into their sinks without necessarily exporting them.

## Go deeper

Reference: `Sources/Observability/Observability.swift` (logging, `MetricsSink`, `Span`, `FeedbackLogStore`), `Sources/Observability/OTLP.swift` (exporter + sinks), `Sources/MemoryStore/Metrics.swift` (the `mem.*` catalog), and `docs/DEVELOPMENT.md` §7 / `docs/codex-swift-memory-wiki.md` §8.
