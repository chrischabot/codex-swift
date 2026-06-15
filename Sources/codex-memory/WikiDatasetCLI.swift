import Foundation
import MemoryStore
import MediaDecode   // SandboxedMediaDecoder.stat (the --sandbox profiling path)

/// `codex-memory wiki-dataset <verb> [flags]` — index large/external/mutable data with
/// manifests + notes (samples / profiles / query-recipes). The wiki is the interface;
/// the data stays put. REMOTE datasets record planned steps and fetch NOTHING; LOCAL
/// profiling is BOUNDED (size-capped read, ≤20-row sample) — never loads a whole file,
/// never stores secrets beyond a capped, flagged sample.
///
/// Verbs:
///   list  [--status S --include-archived --limit N --json]
///   add   --id D --title T --status S --storage (local|remote|external|hybrid)
///         [--locations --formats --license --summary --refresh-cadence]
///   show  <dataset-id> [--json]
///   profile <dataset-id> --path <local-file> [--rows N] [--sandbox]   (--sandbox: stat under Seatbelt)
///   note  <dataset-id> --kind (sample|profile|query) --title T --body B
enum CodexMemoryWikiDataset {
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static let storages: Set<String> = ["local", "remote", "external", "hybrid"]
    static let statuses: Set<String> = ["proposed", "active", "external", "archived", "unavailable"]
    static let noteKinds: Set<String> = ["sample", "profile", "query"]
    static let maxSampleRows = DatasetProfiler.hardSampleCap

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        guard let verb = args.first, !verb.hasPrefix("-") else {
            throw CLIError(message: "wiki-dataset requires a verb (list|add|show|profile|note)")
        }
        let rest = Array(args.dropFirst())
        let bundle = try await CodexMemoryRun.assemble()
        let now = Int64(Date().timeIntervalSince1970)

        switch verb {
        case "list":
            let o = try parseList(rest)
            let m = try await bundle.store.datasetManifests(status: o.status, includeArchived: o.includeArchived, limit: o.limit)
            return (formatList(m, json: o.json), true)

        case "add":
            let o = try parseAdd(rest)
            let existing = try await bundle.store.datasetManifest(datasetID: o.datasetID)
            let row = manifest(from: o, now: now, createdAt: existing?.createdAt ?? now)
            _ = try await bundle.store.upsertDatasetManifest(row)
            return ("wiki-dataset: \(existing == nil ? "added" : "updated") \(o.datasetID)\n", true)

        case "show":
            guard let id = rest.first, !id.hasPrefix("-") else { throw CLIError(message: "show requires a <dataset-id>") }
            guard let m = try await bundle.store.datasetManifest(datasetID: id) else {
                return ("wiki-dataset: no manifest '\(id)'\n", false)
            }
            let notes = try await bundle.store.datasetNotes(manifestID: m.id)
            return (formatShow(m, notes: notes, json: rest.contains("--json")), true)

        case "profile":
            return try await runProfile(rest, store: bundle.store, now: now)

        case "note":
            let (id, kind, title, body) = try parseNote(rest)
            guard let m = try await bundle.store.datasetManifest(datasetID: id) else {
                return ("wiki-dataset: no manifest '\(id)'\n", false)
            }
            _ = try await bundle.store.addDatasetNote(DatasetNoteRow(manifestID: m.id, noteKind: kind, title: title, bodyMd: body, createdAt: now))
            return ("wiki-dataset: noted (\(kind)) on \(id)\n", true)

        default:
            throw CLIError(message: "unknown wiki-dataset verb '\(verb)' (expected: list|add|show|profile|note)")
        }
    }

    /// `profile` — REMOTE manifests refuse to read; record a planned-steps note instead.
    /// LOCAL/HYBRID manifests profile the given path (bounded) and store a profile + a
    /// capped sample note, updating the manifest's size_bytes/record_count.
    static func runProfile(_ args: [String], store: MemoryStore, now: Int64) async throws -> (String, Bool) {
        var id = "", path: String?; var rows = maxSampleRows; var sandbox = false; var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--path": path = try val("--path")
            case "--sandbox": sandbox = true   // stat under the Seatbelt child (untrusted files)
            case "--rows":
                guard let n = Int(try val("--rows")), n > 0 else { throw CLIError(message: "--rows must be a positive integer") }
                rows = min(n, maxSampleRows)   // hard cap — never store more than 20 rows
            default:
                if args[i].hasPrefix("-") { throw CLIError(message: "unknown flag \(args[i])") }
                if id.isEmpty { id = args[i] } else { throw CLIError(message: "unexpected argument \(args[i])") }
            }
            i += 1
        }
        guard !id.isEmpty else { throw CLIError(message: "profile requires a <dataset-id>") }
        guard let m = try await store.datasetManifest(datasetID: id) else { return ("wiki-dataset: no manifest '\(id)'\n", false) }

        if m.storage == "remote" || m.storage == "external" {
            let plan = "Remote dataset — fetched nothing. Planned steps: 1) authenticate at the location; "
                + "2) stream-sample \(rows) rows server-side; 3) record schema + size offline."
            _ = try await store.addDatasetNote(DatasetNoteRow(manifestID: m.id, noteKind: "query",
                                                              title: "remote profiling plan", bodyMd: plan, createdAt: now))
            return ("wiki-dataset: \(id) is \(m.storage) — recorded a planned-steps note, fetched nothing\n", true)
        }
        guard let path else { throw CLIError(message: "profile requires --path for a \(m.storage) dataset") }
        let profile = sandbox
            ? await DatasetProfiler.profileSandboxed(path: path, rowCap: rows)
            : DatasetProfiler.profileLocalFile(path: path, rowCap: rows)
        guard let p = profile else {
            return ("wiki-dataset: could not \(sandbox ? "sandbox-stat" : "read") '\(path)'\n", false)
        }
        let lineStr = p.lineCount < 0 ? "≥\(p.sample.count) (file exceeds the read cap)" : String(p.lineCount)
        let profileBody = "Local file `\(path)`\n- size: \(p.sizeBytes) bytes\n- lines: \(lineStr)\n"
            + (p.truncated ? "- NOTE: only the first chunk was read (bounded profiling)\n" : "")
        _ = try await store.addDatasetNote(DatasetNoteRow(manifestID: m.id, noteKind: "profile",
                                                          title: "profile of \(path)", bodyMd: profileBody, createdAt: now))
        let sampleBody = "SAMPLE — first \(p.sample.count) row(s) (capped; may contain sensitive data, review before sharing):\n\n```\n"
            + p.sample.joined(separator: "\n") + "\n```\n"
        _ = try await store.addDatasetNote(DatasetNoteRow(manifestID: m.id, noteKind: "sample",
                                                          title: "sample of \(path)", bodyMd: sampleBody, createdAt: now))
        // refresh the manifest's size; record_count only when we counted the WHOLE file.
        var updated = m
        updated.sizeBytes = p.sizeBytes
        if p.lineCount >= 0 { updated.recordCount = Int64(p.lineCount) }
        updated.updatedAt = now
        _ = try await store.upsertDatasetManifest(updated)
        return ("wiki-dataset: profiled \(id) (\(p.sizeBytes) bytes, \(lineStr) lines, \(p.sample.count)-row sample)\n", true)
    }

    // MARK: - pure builders / formatters

    struct AddOptions {
        var datasetID = "", title = "", status = "proposed", storage = "external"
        var locations: String?, formats: String?, license: String?, summary: String?, refreshCadence: String?
    }

    static func manifest(from o: AddOptions, now: Int64, createdAt: Int64) -> DatasetManifestRow {
        DatasetManifestRow(datasetID: o.datasetID, title: o.title, status: o.status, storage: o.storage,
                           locations: o.locations, formats: o.formats, license: o.license,
                           refreshCadence: o.refreshCadence, summary: o.summary, createdAt: createdAt, updatedAt: now)
    }

    static func formatList(_ manifests: [DatasetManifestRow], json: Bool) -> String {
        if json {
            let rows = manifests.map { m -> [String: Any] in
                ["datasetID": m.datasetID, "title": m.title, "status": m.status, "storage": m.storage,
                 "sizeBytes": m.sizeBytes.map { NSNumber(value: $0) } as Any, "recordCount": m.recordCount.map { NSNumber(value: $0) } as Any]
                    .compactMapValues { ($0 is NSNull) ? nil : $0 }
            }
            let d = (try? JSONSerialization.data(withJSONObject: ["count": manifests.count, "datasets": rows],
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-dataset: \(manifests.count) manifest(s)\n"
        for m in manifests {
            out += "  \(m.datasetID)  [\(m.status) · \(m.storage)]  \(m.title.prefix(50))\n"
        }
        return out
    }

    static func formatShow(_ m: DatasetManifestRow, notes: [DatasetNoteRow], json: Bool) -> String {
        if json {
            var obj: [String: Any] = ["datasetID": m.datasetID, "title": m.title, "status": m.status, "storage": m.storage,
                                      "notes": notes.map { ["kind": $0.noteKind, "title": $0.title] }]
            if let s = m.sizeBytes { obj["sizeBytes"] = NSNumber(value: s) }
            if let r = m.recordCount { obj["recordCount"] = NSNumber(value: r) }
            if let l = m.locations { obj["locations"] = l }
            if let su = m.summary { obj["summary"] = su }
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "\(m.datasetID)  [\(m.status) · \(m.storage)]\n  \(m.title)\n"
        if let s = m.sizeBytes { out += "  size: \(s) bytes\n" }
        if let r = m.recordCount { out += "  records: \(r)\n" }
        if let l = m.locations { out += "  locations: \(l)\n" }
        out += "  notes: \(notes.count)\n"
        for n in notes { out += "    · [\(n.noteKind)] \(n.title)\n" }
        return out
    }

    // MARK: - parsers

    static func parseAdd(_ args: [String]) throws -> AddOptions {
        var o = AddOptions(); var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--id": o.datasetID = try val("--id")
            case "--title": o.title = try val("--title")
            case "--status": o.status = try val("--status")
            case "--storage": o.storage = try val("--storage")
            case "--locations": o.locations = try val("--locations")
            case "--formats": o.formats = try val("--formats")
            case "--license": o.license = try val("--license")
            case "--summary": o.summary = try val("--summary")
            case "--refresh-cadence": o.refreshCadence = try val("--refresh-cadence")
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        guard !o.datasetID.isEmpty else { throw CLIError(message: "add requires --id") }
        guard !o.title.isEmpty else { throw CLIError(message: "add requires --title") }
        guard storages.contains(o.storage) else { throw CLIError(message: "--storage must be one of: \(storages.sorted().joined(separator: "|"))") }
        guard statuses.contains(o.status) else { throw CLIError(message: "--status must be one of: \(statuses.sorted().joined(separator: "|"))") }
        return o
    }

    struct ListOptions { var status: String?; var includeArchived = false, json = false, limit = 50 }
    static func parseList(_ args: [String]) throws -> ListOptions {
        var o = ListOptions(); var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--status": o.status = try val("--status")
            case "--include-archived": o.includeArchived = true
            case "--json": o.json = true
            case "--limit":
                guard let n = Int(try val("--limit")), n > 0 else { throw CLIError(message: "--limit must be a positive integer") }
                o.limit = n
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        return o
    }

    static func parseNote(_ args: [String]) throws -> (id: String, kind: String, title: String, body: String) {
        var id = "", kind = "", title = "", body = ""; var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--kind": kind = try val("--kind")
            case "--title": title = try val("--title")
            case "--body": body = try val("--body")
            default:
                if args[i].hasPrefix("-") { throw CLIError(message: "unknown flag \(args[i])") }
                if id.isEmpty { id = args[i] } else { throw CLIError(message: "unexpected argument \(args[i])") }
            }
            i += 1
        }
        guard !id.isEmpty, !title.isEmpty, !body.isEmpty else { throw CLIError(message: "note requires <dataset-id> --title --body") }
        guard noteKinds.contains(kind) else { throw CLIError(message: "--kind must be one of: \(noteKinds.sorted().joined(separator: "|"))") }
        return (id, kind, title, body)
    }
}

/// Bounded LOCAL-file profiler: reads at most `byteCap` bytes (never loads a whole
/// file), reports size + an exact line count ONLY when the whole file fit in the cap,
/// and returns a capped, per-line-truncated sample. Used by `wiki-dataset profile`.
struct DatasetProfile: Sendable, Equatable {
    var sizeBytes: Int64
    var lineCount: Int       // -1 when the file exceeded the read cap (count unknown)
    var sample: [String]
    var truncated: Bool      // the file was larger than the read cap
}

enum DatasetProfiler {
    /// Absolute ceiling on the stored sample, enforced INSIDE the profiler (defense in
    /// depth) so no caller — present or future (RPC/sandbox) — can exfiltrate more.
    static let hardSampleCap = 20

    static func profileLocalFile(path: String, rowCap: Int = 20, byteCap: Int = 256 * 1024) -> DatasetProfile? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: byteCap)) ?? Data()   // bounded — never loads a whole file
        let truncated = Int64(data.count) < size
        // Normalize CRLF/CR → LF first: Swift treats "\r\n" as a SINGLE Character, so a
        // raw split on "\n" miscounts every Windows-authored CSV as one line.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // drop the single trailing empty from a final newline
        let cap = min(max(1, rowCap), hardSampleCap)
        let sample = lines.prefix(cap).map { String($0.prefix(500)) }
        // Exact count only when the whole file fit within the read cap.
        let lineCount = truncated ? -1 : lines.count
        return DatasetProfile(sizeBytes: size, lineCount: lineCount, sample: sample, truncated: truncated)
    }

    /// `--sandbox` profiling: run the bounded stat inside the Seatbelt `codex-mediadecode`
    /// child (read-only, no-network, rlimit-capped) instead of in-process — for stat-ing
    /// UNTRUSTED data files. Maps the typed `MediaStatResult` back into a `DatasetProfile`
    /// (sample re-trimmed to the caller's rowCap; the child already hard-caps at 20).
    /// Returns nil on any sandbox failure (helper unavailable / oversize / unreadable).
    static func profileSandboxed(path: String, rowCap: Int = 20) async -> DatasetProfile? {
        switch await SandboxedMediaDecoder().stat(path: path) {
        case .success(let s):
            let cap = min(max(1, rowCap), hardSampleCap)
            return DatasetProfile(sizeBytes: Int64(s.byteSize), lineCount: s.lineCount,
                                  sample: Array(s.sample.prefix(cap)), truncated: s.truncated)
        case .failure:
            return nil
        }
    }
}
