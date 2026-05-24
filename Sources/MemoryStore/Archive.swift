import Foundation
import InfraPrimitives

/// Append-only JSONL archive for the memory subsystem. Mirrors the role of
/// `Persistence/Rollout.swift` for sessions: the JSONL is the source of truth,
/// the SQLite store is a deterministically-replayable index built from it.
/// Each line is a single `ArchiveRecord` JSON object; records are written
/// with a group-commit fsync window so the worker doesn't pay one syscall
/// per record on a 200-doc/day stream.
///
/// File layout under the CodexKit data dir:
///
///   memory/
///     archive/
///       2026/05/2026-05-23.jsonl       (current day's appends)
///       2026/05/2026-05-22.jsonl
///       …
///       snapshots/
///         memory.db.2026-05-23.bak     (VACUUM INTO targets, written by the
///                                       daemon's nightly snapshot job)
///
/// Daily rotation keeps `git`-driven retention manageable; the snapshot
/// scheduler keeps 30 days of rotation on disk.
public actor MemoryArchive {
    public struct ArchiveRecord: Sendable, Codable {
        public var kind: String              // "document" | "extraction" | "insight"
        public var ts: Int64
        public var sourceURI: String?
        public var documentID: Int64?
        public var bodyPath: String?
        public var contentSHA: String?
        public var payload: String?          // arbitrary inner JSON

        public init(kind: String, ts: Int64,
                    sourceURI: String? = nil,
                    documentID: Int64? = nil,
                    bodyPath: String? = nil,
                    contentSHA: String? = nil,
                    payload: String? = nil) {
            self.kind = kind; self.ts = ts
            self.sourceURI = sourceURI
            self.documentID = documentID
            self.bodyPath = bodyPath
            self.contentSHA = contentSHA
            self.payload = payload
        }
    }

    nonisolated public let root: String
    private let encoder: JSONEncoder
    private let dateFormatter: DateFormatter

    public init(root: String) {
        self.root = root
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = e
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy/MM/yyyy-MM-dd"
        self.dateFormatter = f
        try? FileManager.default.createDirectory(
            atPath: root + "/snapshots",
            withIntermediateDirectories: true)
    }

    /// Compute the deterministic body-archive path for a document. The path
    /// is content-addressed — keyed on the content SHA — so callers can
    /// stamp `document.body_path` *before* the body file is written. If the
    /// later write fails, the row still points at the canonical location
    /// (which a retry will fill); the SHA never drifts away from the file
    /// because both come from the same input bytes.
    public nonisolated func bodyPath(sourceURI: String,
                                     ts: Int64,
                                     contentSHA: Data) -> String {
        let hex = contentSHA.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(2))
        return bodyDirectory(for: ts) + "/\(prefix)/\(hex).txt"
    }

    /// Append the raw body for a freshly-fetched document, plus a manifest
    /// record. Idempotent on the content SHA: a re-ingest with the same
    /// bytes is a no-op for the body file (the path already matches) and
    /// still appends a manifest record so replays remain deterministic.
    public func writeDocument(sourceURI: String,
                              documentID: Int64,
                              ts: Int64,
                              bodyText: String,
                              contentSHA: Data) throws -> String {
        let bodyPath = bodyPath(sourceURI: sourceURI, ts: ts, contentSHA: contentSHA)
        try ensureDir((bodyPath as NSString).deletingLastPathComponent)
        if !FileManager.default.fileExists(atPath: bodyPath) {
            try bodyText.write(toFile: bodyPath, atomically: true, encoding: .utf8)
        }
        let manifest = ArchiveRecord(
            kind: "document", ts: ts,
            sourceURI: sourceURI, documentID: documentID,
            bodyPath: bodyPath,
            contentSHA: contentSHA.map { String(format: "%02x", $0) }.joined())
        try appendRecord(manifest, ts: ts)
        return bodyPath
    }

    /// Append an extraction record summarising the entities/edges/chunks
    /// produced for a document.
    public func writeExtraction(documentID: Int64,
                                ts: Int64,
                                payloadJSON: String) throws {
        let record = ArchiveRecord(
            kind: "extraction", ts: ts,
            documentID: documentID, payload: payloadJSON)
        try appendRecord(record, ts: ts)
    }

    /// Append an insight-card record produced by a BrainGate escalation.
    public func writeInsight(documentID: Int64,
                             ts: Int64,
                             cardMarkdown: String) throws {
        let record = ArchiveRecord(
            kind: "insight", ts: ts,
            documentID: documentID, payload: cardMarkdown)
        try appendRecord(record, ts: ts)
    }

    /// `git`-commit the current archive contents. Best-effort: silently
    /// noops if git isn't installed or the archive isn't a working tree.
    /// Called by the nightly snapshot scheduler.
    public func snapshotIntoGit(commitMessage: String) {
        let archive = root
        if !FileManager.default.fileExists(atPath: archive + "/.git") {
            _ = run(args: ["init", "-q"], cwd: archive)
        }
        _ = run(args: ["add", "."], cwd: archive)
        _ = run(args: ["-c", "user.email=memory@codexkit.local",
                       "-c", "user.name=CodexKit Memory",
                       "commit", "-q", "-m", commitMessage,
                       "--allow-empty"], cwd: archive)
    }

    /// Remove archive files older than `retentionDays` and snapshot backups
    /// past the same window. Designed to be called from the nightly job.
    public func prune(retentionDays: Int = 30, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays * 86_400))
        prune(directory: root, olderThan: cutoff, allowedExt: ["jsonl", "txt"])
        prune(directory: root + "/snapshots", olderThan: cutoff,
              allowedExt: ["bak"])
    }

    /// Path the current day's JSONL append target ends up at — exposed for
    /// the nightly snapshot job and tests.
    public func currentArchivePath(ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        return root + "/" + dateFormatter.string(from: date) + ".jsonl"
    }

    // MARK: - private

    private nonisolated func bodyDirectory(for ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy/MM/dd"
        return root + "/bodies/" + f.string(from: date)
    }

    private func ensureDir(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }

    private func appendRecord(_ record: ArchiveRecord, ts: Int64) throws {
        let path = currentArchivePath(ts: ts)
        try ensureDir((path as NSString).deletingLastPathComponent)
        var line = try encoder.encode(record)
        line.append(0x0A)  // newline
        if !FileManager.default.fileExists(atPath: path) {
            try line.write(to: URL(fileURLWithPath: path))
            return
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    @discardableResult
    private func run(args: [String], cwd: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    private func prune(directory: String, olderThan cutoff: Date,
                       allowedExt: Set<String>) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory) else { return }
        while let path = enumerator.nextObject() as? String {
            let full = directory + "/" + path
            let ext = (path as NSString).pathExtension
            guard allowedExt.contains(ext) else { continue }
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let mtime = attrs[.modificationDate] as? Date,
               mtime < cutoff {
                try? fm.removeItem(atPath: full)
            }
        }
    }
}

/// Convenience factory: derives the archive root from the standard CodexKit
/// data dir layout used by `MemoryStoreConfig.defaultPath()`.
public extension MemoryArchive {
    static func open(codexHome: String) -> MemoryArchive {
        let dir = codexHome + "/memory/archive"
        return MemoryArchive(root: dir)
    }
}
