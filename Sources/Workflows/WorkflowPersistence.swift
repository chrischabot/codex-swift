import Foundation

/// Append-only `journal.jsonl` per run (port of Claude's `LocalFileJournal`).
/// One JSON object per line: `{"type":"started",...}` / `{"type":"result",...}`.
/// `result` lines are appended only when the value is non-null so skipped
/// agents re-attempt on resume.
public actor WorkflowJournal {
    private let path: String
    private let fh: FileHandle?

    public init(path: String) {
        self.path = path
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        self.fh = FileHandle(forWritingAtPath: path)
        try? self.fh?.seekToEnd()
    }

    public func appendStarted(key: String, agentId: Int) {
        write(["type": "started", "key": key, "agentId": agentId])
    }

    /// `resultJSON` is the JSON-serialized value. Skipped (null) results are
    /// NOT journaled.
    public func appendResult(key: String, agentId: Int, resultJSON: String) {
        if resultJSON == "null" { return }
        // Embed the result value as parsed JSON (not a string) for fidelity.
        let line = "{\"type\":\"result\",\"key\":\(WorkflowJournal.jsonString(key)),\"agentId\":\(agentId),\"result\":\(resultJSON)}\n"
        if let d = line.data(using: .utf8) { try? fh?.write(contentsOf: d) }
        try? fh?.synchronizeFile()
    }

    private func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              var s = String(data: d, encoding: .utf8) else { return }
        s += "\n"
        if let dd = s.data(using: .utf8) { try? fh?.write(contentsOf: dd) }
        try? fh?.synchronizeFile()
    }

    private static func jsonString(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: d, encoding: .utf8) { return String(str.dropFirst().dropLast()) }
        return "\"\(s)\""
    }

    /// Load the journal into an index. Result lines (last-wins) carry the cached
    /// value re-serialized as a JSON string.
    public static func loadIndex(path: String) -> JournalIndex {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return JournalIndex() }
        var idx = JournalIndex()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let type = obj["type"] as? String,
                  let key = obj["key"] as? String else { continue }
            let agentId = (obj["agentId"] as? Int) ?? Int((obj["agentId"] as? Double) ?? 0)
            if type == "started" {
                idx.started[key, default: []].append(agentId)
            } else if type == "result" {
                let value = obj["result"] as Any? ?? NSNull()
                if let dd = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                   let s = String(data: dd, encoding: .utf8) {
                    idx.results[key] = s
                }
            }
        }
        return idx
    }
}

/// Per-run persistence: run directories, snapshot JSON, persisted scripts.
/// Lives under `<codexHome>/workflows/`.
public struct WorkflowStore: Sendable {
    public let root: String   // <codexHome>/workflows

    public init(codexHome: String) {
        self.root = codexHome + "/workflows"
        try? FileManager.default.createDirectory(atPath: root + "/runs", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/scripts", withIntermediateDirectories: true)
    }

    public enum StoreError: Error, Equatable { case unsafeRunId(String) }

    /// Reject path-traversal / separators in run ids before using them as dir
    /// names (port of `ensureSafe`).
    public static func isSafeRunId(_ id: String) -> Bool {
        if id.isEmpty || id.contains("/") || id.contains("..") || id.contains("\u{0}") { return false }
        return id.range(of: WF.runIdRegex, options: .regularExpression) != nil
    }

    public func runDir(_ runId: String) throws -> String {
        guard Self.isSafeRunId(runId) else { throw StoreError.unsafeRunId(runId) }
        let dir = root + "/runs/" + runId
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    public func journalPath(_ runId: String) throws -> String { try runDir(runId) + "/journal.jsonl" }
    public func snapshotPath(_ runId: String) throws -> String { try runDir(runId) + "/snapshot.json" }

    /// Persist a script body so the model can iterate via `scriptPath`.
    @discardableResult
    public func persistScript(_ body: String, slug: String, runId: String) -> String? {
        let safeSlug = slug.isEmpty ? "workflow" : slug
        let path = root + "/scripts/\(safeSlug)-\(runId).js"
        try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    public func writeSnapshot(_ snapshot: [String: Any], runId: String) {
        guard let path = try? snapshotPath(runId),
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Read all snapshots newest-first (by `startTime`).
    public func readSnapshots() -> [[String: Any]] {
        let runsDir = root + "/runs"
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: runsDir) else { return [] }
        var out: [[String: Any]] = []
        for id in ids {
            let p = runsDir + "/" + id + "/snapshot.json"
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            out.append(obj)
        }
        out.sort { a, b in
            let sa = (a["startTime"] as? Double) ?? 0
            let sb = (b["startTime"] as? Double) ?? 0
            return sa > sb
        }
        return out
    }
}
