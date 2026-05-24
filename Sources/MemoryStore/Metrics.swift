import Foundation
import Observability

/// Shared metrics sink for the Memory Wiki. The design doc §8 names every
/// counter and gauge; this is the in-process ring they all push into. The
/// daemon's OTLP exporter drains it on the existing cadence.
///
/// All names use the `mem.*` prefix per spec. Tags carry source-kind or
/// model-id labels when relevant. The ring is capacity-bounded (4096 points
/// by default) and overwrite-on-full so telemetry never back-pressures the
/// hot path.
public enum MemoryMetrics {
    public static let sink = MetricsSink(capacity: 4096)

    public static func ingestDoc(source: String, bytes: Int) {
        sink.count("mem.ingest.docs", tag: source, 1)
        sink.count("mem.ingest.bytes", tag: source, Double(bytes))
    }

    public static func chunkCreated(count: Int = 1) {
        sink.count("mem.chunks.created", tag: "", Double(count))
    }

    public static func embeddingCreated(count: Int = 1) {
        sink.count("mem.embeddings.created", tag: "", Double(count))
    }

    public static func extractTokens(input: Int, output: Int, model: String) {
        sink.count("mem.extract.tokens", tag: "\(model)/in", Double(input))
        sink.count("mem.extract.tokens", tag: "\(model)/out", Double(output))
    }

    public static func gatePass(score: Double) {
        sink.count("mem.score.gate_pass", tag: "", 1)
        sink.gauge("mem.score.gate_pass_score", tag: "", score)
    }

    public static func brainCall(model: String, tokensIn: Int, tokensOut: Int, costUSD: Double) {
        sink.count("mem.brain.calls", tag: model, 1)
        sink.count("mem.brain.tokens_in", tag: model, Double(tokensIn))
        sink.count("mem.brain.tokens_out", tag: model, Double(tokensOut))
        sink.count("mem.brain.cost_usd", tag: model, costUSD)
    }

    public static func ringDropped(_ name: String) {
        // Must stay zero — anything that's not zero is an alert.
        sink.count("mem.ring.dropped", tag: name, 1)
    }

    public static func walBytes(_ bytes: Int64) {
        sink.gauge("mem.store.wal_bytes", tag: "", Double(bytes))
    }
}
