import XCTest
import Foundation
@testable import Observability
@testable import InfraPrimitives

private actor CapturingSink: OTLPSink {
    private(set) var bodies: [Data] = []
    func send(_ jsonBody: Data) async -> Bool { bodies.append(jsonBody); return true }
    func count() -> Int { bodies.count }
    func last() -> Data? { bodies.last }
}

final class ObservabilityTests: XCTestCase {

    private func obj(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func testOTLPEncodingShape() {
        let exp = OTLPMetricsExporter(serviceName: "codexkit-test")
        let pts = [
            MetricPoint(atMonotonic: 1.0, name: "turns", tag: "ok",
                        value: 3, kind: "count"),
            MetricPoint(atMonotonic: 2.0, name: "turn.duration", tag: "",
                        value: 0.42, kind: "duration"),
            MetricPoint(atMonotonic: 3.0, name: "queue.depth", tag: "c2",
                        value: 7, kind: "gauge"),
        ]
        let o = obj(exp.encode(pts))
        guard let rm = (o["resourceMetrics"] as? [[String: Any]])?.first,
              let res = rm["resource"] as? [String: Any],
              let resAttrs = res["attributes"] as? [[String: Any]],
              let sm = (rm["scopeMetrics"] as? [[String: Any]])?.first,
              let metrics = sm["metrics"] as? [[String: Any]] else {
            return XCTFail("malformed OTLP envelope")
        }
        XCTAssertEqual(resAttrs.first?["key"] as? String, "service.name")
        XCTAssertEqual(metrics.count, 3)
        let byName = Dictionary(uniqueKeysWithValues:
            metrics.map { ($0["name"] as? String ?? "", $0) })
        // count → monotonic sum.
        let sum = byName["turns"]?["sum"] as? [String: Any]
        XCTAssertEqual(sum?["isMonotonic"] as? Bool, true)
        XCTAssertEqual(sum?["aggregationTemporality"] as? Int, 2)
        let sdp = (sum?["dataPoints"] as? [[String: Any]])?.first
        XCTAssertEqual(sdp?["asDouble"] as? Double, 3)
        let sAttrs = sdp?["attributes"] as? [[String: Any]]
        XCTAssertEqual(sAttrs?.first?["key"] as? String, "tag")
        // duration & gauge → gauge.
        XCTAssertNotNil(byName["turn.duration"]?["gauge"])
        XCTAssertNotNil(byName["queue.depth"]?["gauge"])
        // Empty tag → no attributes.
        let dDP = ((byName["turn.duration"]?["gauge"] as? [String: Any])?["dataPoints"]
                   as? [[String: Any]])?.first
        XCTAssertEqual((dDP?["attributes"] as? [[String: Any]])?.count, 0)
    }

    func testDisabledSinkIsNoOpAndEmptyBatchSkips() async {
        let exp = OTLPMetricsExporter()   // DisabledOTLPSink default
        let ok = await exp.export([
            MetricPoint(atMonotonic: 0, name: "x", tag: "", value: 1, kind: "count")])
        XCTAssertTrue(ok)
        let empty = await exp.export([])
        XCTAssertTrue(empty, "empty batch is a no-op success")
    }

    func testDrainAndExportDrainsMetricsSink() async {
        let cap = CapturingSink()
        let exp = OTLPMetricsExporter(serviceName: "svc", sink: cap)
        let sink = MetricsSink(capacity: 64)
        sink.count("turn.start", tag: "t1")
        sink.observeDuration("turn.dur", tag: "t1", seconds: 0.1)
        sink.gauge("depth", tag: "c2", 5)
        let ok = await exp.drainAndExport(sink)
        XCTAssertTrue(ok)
        let n = await cap.count()
        XCTAssertEqual(n, 1, "one OTLP batch sent")
        guard let body = await cap.last() else { return XCTFail("no body") }
        let o = obj(body)
        let rm = (o["resourceMetrics"] as? [[String: Any]])?.first
        let sm = (rm?["scopeMetrics"] as? [[String: Any]])?.first
        let metrics = sm?["metrics"] as? [[String: Any]] ?? []
        let names = Set(metrics.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["turn.start", "turn.dur", "depth"])
        // Draining again yields nothing (ring already drained).
        let again = await exp.drainAndExport(sink)
        XCTAssertTrue(again)
        let n2 = await cap.count()
        XCTAssertEqual(n2, 1, "no second batch for an empty drain")
    }

    func testFeedbackLogStoreFiltersAndRendersBoundedNewestSuffix() {
        let store = FeedbackLogStore(capacity: 4, maxRenderedBytes: 140, maxLineBytes: 90)
        store.record(FeedbackLogEntry(timestamp: Date(timeIntervalSince1970: 1.123456),
                                      level: .info, category: "test",
                                      message: "old thread row", threadId: "thread-1"))
        store.record(FeedbackLogEntry(timestamp: Date(timeIntervalSince1970: 2),
                                      level: .warn, category: "test",
                                      message: "other thread row", threadId: "thread-2"))
        store.record(FeedbackLogEntry(timestamp: Date(timeIntervalSince1970: 3),
                                      level: .error, category: "test",
                                      message: "threadless row", threadId: nil))
        store.record(FeedbackLogEntry(timestamp: Date(timeIntervalSince1970: 4),
                                      level: .debug, category: "test",
                                      message: String(repeating: "x", count: 120),
                                      threadId: "thread-1"))
        store.record(FeedbackLogEntry(timestamp: Date(timeIntervalSince1970: 5),
                                      level: .info, category: "test",
                                      message: "new thread row\n", threadId: "thread-1"))

        let rendered = String(decoding: store.renderFeedbackLogs(threadIds: ["thread-1"]),
                              as: UTF8.self)
        XCTAssertFalse(rendered.contains("other thread row"))
        XCTAssertFalse(rendered.contains(String(repeating: "x", count: 120)),
                       "oversized feedback log rows are skipped")
        XCTAssertTrue(rendered.contains("threadless row"))
        XCTAssertTrue(rendered.contains("new thread row\n"))
        XCTAssertFalse(rendered.contains("old thread row"),
                       "ring capacity drops oldest rows under pressure")
        XCTAssertGreaterThan(store.droppedCount, 0)
    }

    func testLogWritesToFeedbackLogStore() {
        FeedbackLogStore.shared.clear()
        Log(category: "feedback-test", minLevel: .debug)
            .debug("debug row", threadId: "thread-abc")
        let rendered = String(decoding: FeedbackLogStore.shared.renderFeedbackLogs(threadIds: ["thread-abc"]),
                              as: UTF8.self)
        XCTAssertTrue(rendered.contains("DEBUG debug row"), rendered)
    }
}
