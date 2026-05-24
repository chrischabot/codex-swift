import Foundation
import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where exported OTLP payloads go. Default is `DisabledOTLPSink` (no-op) so
/// the daemon never blocks on telemetry; a real HTTP sink is injected when an
/// OTLP endpoint is configured.
public protocol OTLPSink: Sendable {
    func send(_ jsonBody: Data) async -> Bool
}

public struct DisabledOTLPSink: OTLPSink {
    public init() {}
    public func send(_ jsonBody: Data) async -> Bool { true }
}

/// `@unchecked Sendable` Process box (same pattern as the model/auth clients).
private final class ProcBox3: @unchecked Sendable { let p = Process() }

/// curl-backed OTLP/HTTP sink (portable; works on Linux/macOS without
/// URLSession). POSTs `application/json` to the configured collector.
public struct CurlOTLPSink: OTLPSink {
    public let endpoint: String
    public let headers: [String: String]
    public init(endpoint: String, headers: [String: String] = [:]) {
        self.endpoint = endpoint
        self.headers = headers
    }
    public func send(_ jsonBody: Data) async -> Bool {
        let box = ProcBox3()
        let p = box.p
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["curl", "-sS", "-X", "POST", endpoint,
                    "-H", "Content-Type: application/json", "--data-binary", "@-"]
        for (k, v) in headers { args += ["-H", "\(k): \(v)"] }
        p.arguments = args
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        inPipe.fileHandleForWriting.write(jsonBody)
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Serializes `MetricPoint`s into an OTLP/JSON `ResourceMetrics` document and
/// drains a `MetricsSink` to the configured collector. The encoding is exact
/// and unit-tested; the network egress is the injected sink.
public struct OTLPMetricsExporter: Sendable {
    public let serviceName: String
    private let sink: any OTLPSink

    public init(serviceName: String = "codexkit",
                sink: any OTLPSink = DisabledOTLPSink()) {
        self.serviceName = serviceName
        self.sink = sink
    }

    /// Build the OTLP/JSON body for a batch of points (one Sum/Gauge metric
    /// per point name+kind, attributes carry the tag).
    public func encode(_ points: [MetricPoint]) -> Data {
        func attr(_ key: String, _ val: String) -> [String: Any] {
            ["key": key, "value": ["stringValue": val]]
        }
        let metrics: [[String: Any]] = points.map { p in
            let dp: [String: Any] = [
                "asDouble": p.value,
                "timeUnixNano": String(Int64(p.atMonotonic * 1_000_000_000)),
                "attributes": p.tag.isEmpty ? [] : [attr("tag", p.tag)],
            ]
            switch p.kind {
            case "count":
                return ["name": p.name,
                        "sum": ["aggregationTemporality": 2,
                                "isMonotonic": true,
                                "dataPoints": [dp]]]
            case "duration", "gauge":
                return ["name": p.name, "gauge": ["dataPoints": [dp]]]
            default:
                return ["name": p.name, "gauge": ["dataPoints": [dp]]]
            }
        }
        let doc: [String: Any] = [
            "resourceMetrics": [[
                "resource": ["attributes": [attr("service.name", serviceName)]],
                "scopeMetrics": [["scope": ["name": "codexkit"],
                                  "metrics": metrics]],
            ]],
        ]
        return (try? JSONSerialization.data(
            withJSONObject: doc, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    @discardableResult
    public func export(_ sinkPoints: [MetricPoint]) async -> Bool {
        guard !sinkPoints.isEmpty else { return true }
        return await sink.send(encode(sinkPoints))
    }

    @discardableResult
    public func drainAndExport(_ metrics: MetricsSink) async -> Bool {
        await export(metrics.drain())
    }
}