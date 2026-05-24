import Foundation
import InfraPrimitives

#if canImport(os)
import os
#endif

public struct FeedbackLogEntry: Sendable, Equatable {
    public var timestamp: Date
    public var level: Log.Level
    public var category: String
    public var message: String
    public var threadId: String?

    public init(timestamp: Date = Date(),
                level: Log.Level,
                category: String,
                message: String,
                threadId: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.threadId = threadId
    }
}

public final class FeedbackLogStore: @unchecked Sendable {
    public static let shared = FeedbackLogStore()

    private let lock = NSLock()
    private var entries: [FeedbackLogEntry] = []
    private var dropped = 0
    private let capacity: Int
    private let maxRenderedBytes: Int
    private let maxLineBytes: Int

    public init(capacity: Int = 4096,
                maxRenderedBytes: Int = 5 * 1024 * 1024,
                maxLineBytes: Int = 1024 * 1024) {
        precondition(capacity > 0)
        precondition(maxRenderedBytes > 0)
        precondition(maxLineBytes > 0)
        self.capacity = capacity
        self.maxRenderedBytes = maxRenderedBytes
        self.maxLineBytes = maxLineBytes
    }

    public func record(_ entry: FeedbackLogEntry) {
        lock.lock(); defer { lock.unlock() }
        if entries.count == capacity {
            entries.removeFirst()
            dropped += 1
        }
        entries.append(entry)
    }

    public func snapshot() -> [FeedbackLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        dropped = 0
    }

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    public func renderFeedbackLogs(threadIds: [String]) -> Data {
        let ids = Set(threadIds)
        let rows = snapshot().filter { entry in
            guard let threadId = entry.threadId else { return true }
            return ids.contains(threadId)
        }
        return Self.render(rows, maxRenderedBytes: maxRenderedBytes,
                           maxLineBytes: maxLineBytes)
    }

    public static func render(_ rows: [FeedbackLogEntry],
                              maxRenderedBytes: Int,
                              maxLineBytes: Int) -> Data {
        var renderedNewestFirst: [Data] = []
        var total = 0
        for row in rows.reversed() {
            let line = format(row)
            let data = Data(line.utf8)
            guard data.count <= maxLineBytes else { continue }
            if total + data.count > maxRenderedBytes { break }
            renderedNewestFirst.append(data)
            total += data.count
        }
        var out = Data()
        for data in renderedNewestFirst.reversed() { out.append(data) }
        return out
    }

    public static func format(_ row: FeedbackLogEntry) -> String {
        let ts = feedbackTimestamp(row.timestamp)
        let level = feedbackLevel(row.level)
        let body = row.message.hasSuffix("\n") ? row.message : row.message + "\n"
        return "\(ts) \(level) \(body)"
    }

    private static func feedbackTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func feedbackLevel(_ level: Log.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return " INFO"
        case .warn: return " WARN"
        case .error: return "ERROR"
        }
    }
}

/// Structured, level-filtered logger. On Apple platforms it bridges to
/// `os.Logger`; elsewhere it writes JSON lines to stderr. Hardening §10.
public struct Log: Sendable {
    public enum Level: Int, Sendable, Comparable, Codable {
        case debug = 0, info, warn, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    public let subsystem: String
    public let category: String
    public let minLevel: Level

    public init(subsystem: String = "ai.igent.codexkit",
                category: String,
                minLevel: Level = .info) {
        self.subsystem = subsystem
        self.category = category
        self.minLevel = minLevel
    }

    public func log(_ level: Level, _ message: @autoclosure () -> String,
                    threadId: String? = nil) {
        guard level >= minLevel else { return }
        let msg = message()
        FeedbackLogStore.shared.record(FeedbackLogEntry(
            level: level, category: category, message: msg, threadId: threadId))
        #if canImport(os)
        let logger = os.Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(msg, privacy: .public)")
        case .info:  logger.info("\(msg, privacy: .public)")
        case .warn:  logger.warning("\(msg, privacy: .public)")
        case .error: logger.error("\(msg, privacy: .public)")
        }
        #else
        let line = "{\"ts\":\(MonotonicClock.now()),\"lvl\":\"\(level)\",\"cat\":\"\(category)\",\"msg\":\(Self.jsonString(msg))}"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        #endif
    }

    public func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    public func info(_ m: @autoclosure () -> String)  { log(.info, m()) }
    public func warn(_ m: @autoclosure () -> String)  { log(.warn, m()) }
    public func error(_ m: @autoclosure () -> String) { log(.error, m()) }

    public func debug(_ m: @autoclosure () -> String, threadId: String?) { log(.debug, m(), threadId: threadId) }
    public func info(_ m: @autoclosure () -> String, threadId: String?)  { log(.info, m(), threadId: threadId) }
    public func warn(_ m: @autoclosure () -> String, threadId: String?)  { log(.warn, m(), threadId: threadId) }
    public func error(_ m: @autoclosure () -> String, threadId: String?) { log(.error, m(), threadId: threadId) }

    static func jsonString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
                       .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

/// One metrics datapoint kept tiny + Sendable for the C4 ring.
public struct MetricPoint: Sendable, Codable {
    public let atMonotonic: Double
    public let name: String
    public let tag: String
    public let value: Double
    public let kind: String  // "count" | "duration" | "gauge"
}

/// RED (Rate/Errors/Duration) + saturation emitter. Writes to a C4
/// overwrite-ring drained off the hot path so telemetry never blocks work
/// (hardening §10 / §3.4).
public final class MetricsSink: @unchecked Sendable {
    private let ring: OverwriteRing<MetricPoint>
    public init(capacity: Int) { ring = OverwriteRing(capacity: capacity) }

    public func count(_ name: String, tag: String = "", _ n: Double = 1) {
        ring.push(MetricPoint(atMonotonic: MonotonicClock.now(), name: name,
                              tag: tag, value: n, kind: "count"))
    }
    public func observeDuration(_ name: String, tag: String = "", seconds: Double) {
        ring.push(MetricPoint(atMonotonic: MonotonicClock.now(), name: name,
                              tag: tag, value: seconds, kind: "duration"))
    }
    public func gauge(_ name: String, tag: String = "", _ v: Double) {
        ring.push(MetricPoint(atMonotonic: MonotonicClock.now(), name: name,
                              tag: tag, value: v, kind: "gauge"))
    }
    public func drain() -> [MetricPoint] { ring.drain() }
    public var droppedCount: Int { ring.droppedCount }
}

/// A turn-phase span (prompt build / sample / tool / compact / flush).
/// Hardening §10: emits a real `os_signpost` interval on Apple platforms via
/// `OSSignposter` for Instruments timelines, and always records a duration
/// metric. Non-Apple builds keep the timing record only.
public struct Span: ~Copyable {
    private let name: StaticString
    private let start: Double
    private let sink: MetricsSink?
    private let tag: String

    #if canImport(os)
    private let signposter: OSSignposter?
    private let intervalState: OSSignpostIntervalState?
    #endif

    public init(_ name: StaticString,
                tag: String = "",
                sink: MetricsSink? = nil,
                subsystem: String = "ai.igent.codexkit",
                category: String = "turn") {
        self.name = name
        self.tag = tag
        self.sink = sink
        self.start = MonotonicClock.now()
        #if canImport(os)
        if #available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
            let sp = OSSignposter(subsystem: subsystem, category: category)
            self.signposter = sp
            self.intervalState = sp.beginInterval(name, id: sp.makeSignpostID())
        } else {
            self.signposter = nil
            self.intervalState = nil
        }
        #endif
    }

    deinit {
        let dur = MonotonicClock.now() - start
        sink?.observeDuration(String(describing: name), tag: tag, seconds: dur)
        #if canImport(os)
        if #available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *),
           let sp = signposter, let st = intervalState {
            sp.endInterval(name, st)
        }
        #endif
    }
}
