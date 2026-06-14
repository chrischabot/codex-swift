import Foundation

// Session provenance (§6 "Session provenance"). The three wiki-root files are the
// SOURCE OF TRUTH (the DB rows are a query cache, mirrored by the orchestrator):
//   .research-session.json   — ephemeral live state, for crash recovery
//   .session-events.jsonl    — durable, append-only event log
//   .session-checkpoint.json — atomic, round-granular resume point
// All timestamps are injected (no Date() here) so the engine stays deterministic.

/// One research path (a decomposed sub-question / angle) tracked across rounds.
public struct ResearchPath: Codable, Sendable, Equatable {
    public var id: String
    public var question: String
    public var searchAngles: [String]
    public var status: String   // pending | in_progress | completed | failed
    public init(id: String, question: String, searchAngles: [String], status: String) {
        self.id = id; self.question = question; self.searchAngles = searchAngles; self.status = status
    }
}

/// `.research-session.json` — the live session state (ephemeral; removed on clean
/// completion, persisted as `interrupted` on a crash).
public struct ResearchSession: Codable, Sendable, Equatable {
    public var sessionID: String
    public var command: String          // "research"
    public var mode: ResearchMode
    public var topic: String
    public var startTime: Int64
    public var minTimeBudget: Int64?    // seconds; nil = single round
    public var currentRound: Int
    public var cumulativeSources: Int
    public var cumulativeArticles: Int
    public var status: String           // in_progress | completed | interrupted | failed
    public var lastProgressScore: Int?
    public var paths: [ResearchPath]

    public init(sessionID: String, command: String = "research", mode: ResearchMode, topic: String,
                startTime: Int64, minTimeBudget: Int64? = nil, currentRound: Int = 0,
                cumulativeSources: Int = 0, cumulativeArticles: Int = 0,
                status: String = "in_progress", lastProgressScore: Int? = nil,
                paths: [ResearchPath] = []) {
        self.sessionID = sessionID; self.command = command; self.mode = mode; self.topic = topic
        self.startTime = startTime; self.minTimeBudget = minTimeBudget; self.currentRound = currentRound
        self.cumulativeSources = cumulativeSources; self.cumulativeArticles = cumulativeArticles
        self.status = status; self.lastProgressScore = lastProgressScore; self.paths = paths
    }
}

/// One `.session-events.jsonl` line (durable audit trail).
public struct SessionEvent: Codable, Sendable, Equatable {
    public var ts: Int64
    public var command: String
    public var phase: String            // start | round | reflection | finish
    public var event: String
    public var round: Int?
    public var sourcesIngested: Int?
    public var articlesCompiled: Int?
    public var progressScore: Int?
    public var notes: String?
    public init(ts: Int64, command: String = "research", phase: String, event: String, round: Int? = nil,
                sourcesIngested: Int? = nil, articlesCompiled: Int? = nil,
                progressScore: Int? = nil, notes: String? = nil) {
        self.ts = ts; self.command = command; self.phase = phase; self.event = event; self.round = round
        self.sourcesIngested = sourcesIngested; self.articlesCompiled = articlesCompiled
        self.progressScore = progressScore; self.notes = notes
    }
}

/// `.session-checkpoint.json` — the round-granular resume point (the reliable unit).
public struct SessionCheckpoint: Codable, Sendable, Equatable {
    public var sessionID: String
    public var updatedAt: Int64
    public var status: String
    public var summary: String
    public var round: Int               // the last COMPLETED round
    public init(sessionID: String, updatedAt: Int64, status: String, summary: String, round: Int) {
        self.sessionID = sessionID; self.updatedAt = updatedAt; self.status = status
        self.summary = summary; self.round = round
    }
}

public struct ResearchSessionStore: Sendable {
    public let root: String
    public init(root: String) { self.root = root }

    public var sessionFile: String { root + "/.research-session.json" }
    public var eventsFile: String { root + "/.session-events.jsonl" }
    public var checkpointFile: String { root + "/.session-checkpoint.json" }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }()

    // MARK: live session (atomic replace)

    public func writeSession(_ s: ResearchSession) throws {
        try ensureRoot()
        try atomicWrite(sessionFile, try Self.encoder.encode(s))
    }
    public func readSession() throws -> ResearchSession? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: sessionFile)) else { return nil }
        return try JSONDecoder().decode(ResearchSession.self, from: d)
    }
    /// Remove the ephemeral live-state file on clean completion (events + checkpoint
    /// stay as the durable record).
    public func clearSession() throws {
        try? FileManager.default.removeItem(atPath: sessionFile)
    }

    // MARK: event log (append-only)

    public func appendEvent(_ e: SessionEvent) throws {
        try ensureRoot()
        var line = try Self.encoder.encode(e)
        line.append(0x0A)   // newline
        let url = URL(fileURLWithPath: eventsFile)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)   // first event creates the file
        }
    }
    public func readEvents() throws -> [SessionEvent] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: eventsFile)) else { return [] }
        let dec = JSONDecoder()
        return String(decoding: d, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? dec.decode(SessionEvent.self, from: Data($0.utf8)) }
    }

    // MARK: checkpoint (atomic replace) + resume

    public func writeCheckpoint(_ c: SessionCheckpoint) throws {
        try ensureRoot()
        try atomicWrite(checkpointFile, try Self.encoder.encode(c))
    }
    public func readCheckpoint() throws -> SessionCheckpoint? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: checkpointFile)) else { return nil }
        return try JSONDecoder().decode(SessionCheckpoint.self, from: d)
    }

    /// `--resume` at round granularity: the next round to run is the last COMPLETED
    /// round + 1. nil if there's no checkpoint or the session already completed.
    public func resumeRound() throws -> Int? {
        guard let cp = try readCheckpoint() else { return nil }
        if cp.status == "completed" { return nil }
        return cp.round + 1
    }

    // MARK: helpers

    private func ensureRoot() throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root, isDirectory: &isDir) {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
    }
    /// Write to a sibling temp file then rename — a POSIX-atomic replace, so a crash
    /// mid-write never leaves a torn session/checkpoint file.
    private func atomicWrite(_ path: String, _ data: Data) throws {
        let tmp = path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        try data.write(to: URL(fileURLWithPath: tmp))
        // rename(2) is atomic on the same filesystem.
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)   // fallback
        }
    }
}
