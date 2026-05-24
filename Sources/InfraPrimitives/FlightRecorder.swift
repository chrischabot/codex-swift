import Foundation

/// One structured flight-recorder entry. Kept tiny and `Sendable`.
public struct FlightEvent: Sendable, Codable {
    public let atMonotonic: Double
    public let kind: String          // e.g. "submission","turn.start","model.request","error"
    public let detail: String
    public init(kind: String, detail: String) {
        self.atMonotonic = MonotonicClock.now()
        self.kind = kind
        self.detail = detail
    }
}

/// Per-session flight recorder: a fixed overwrite ring of the last N events.
/// Hardening §3.3 / §10: dumped on crash/quarantine/SLO-breach so postmortem
/// is deterministic without always-on verbose logging cost.
public final class FlightRecorder: @unchecked Sendable {
    private let ring: OverwriteRing<FlightEvent>

    public init(capacity: Int) {
        self.ring = OverwriteRing<FlightEvent>(capacity: capacity)
    }

    public func record(_ kind: String, _ detail: String) {
        ring.push(FlightEvent(kind: kind, detail: detail))
    }

    /// Dump oldest→newest as JSON lines for postmortem.
    public func dumpJSONL() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return ring.snapshot().compactMap { ev in
            (try? enc.encode(ev)).map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n")
    }

    public func snapshot() -> [FlightEvent] { ring.snapshot() }
}