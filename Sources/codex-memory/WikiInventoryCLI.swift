import Foundation
import MemoryStore

/// `codex-memory wiki-inventory <verb> [flags]` — durable inventory of items /
/// ingest-candidates / entities / corpora / open-questions / tasks / artifacts /
/// watch-items. The list view is a compact-table SQL projection (dedicated columns,
/// never reads bodies). No model, no network — pure local CRUD over the curation store.
///
/// Verbs:
///   list  [--kind K --status S --include-archived --limit N --json]
///   add   --slug S --kind K --title T [--status --priority --summary --next-action
///                                      --tags --origin --confidence --body]
///   show  <slug> [--json]
///   save-view --slug S --title T [--filters JSON]
///   views [--json]
enum CodexMemoryWikiInventory {
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static let kinds: Set<String> = ["item", "ingest-candidate", "entity", "corpus", "question", "task", "artifact", "watch"]
    static let statuses: Set<String> = ["proposed", "active", "blocked", "ingested", "superseded", "archived"]

    struct AddOptions {
        var slug = "", kind = "", title = ""
        var status = "proposed", priority = "p2"
        var summary: String?, nextAction: String?, tags: String?, origin: String?, confidence: String?, body: String?
    }
    struct ListOptions {
        var kind: String?, status: String?
        var includeArchived = false, json = false, limit = 50
    }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        guard let verb = args.first, !verb.hasPrefix("-") else {
            throw CLIError(message: "wiki-inventory requires a verb (list|add|show|save-view|views)")
        }
        let rest = Array(args.dropFirst())
        let bundle = try await CodexMemoryRun.assemble()
        let now = Int64(Date().timeIntervalSince1970)

        switch verb {
        case "list":
            let o = try parseList(rest)
            let records = try await bundle.store.inventoryRecords(kind: o.kind, status: o.status,
                                                                 includeArchived: o.includeArchived, limit: o.limit)
            return (formatList(records, json: o.json), true)

        case "add":
            let o = try parseAdd(rest)
            let existing = try await bundle.store.inventoryRecord(slug: o.slug)
            let row = record(from: o, now: now, createdAt: existing?.createdAt ?? now)
            let id = try await bundle.store.upsertInventoryRecord(row)
            return ("wiki-inventory: \(existing == nil ? "added" : "updated") \(o.slug) (id \(id))\n", true)

        case "show":
            guard let slug = rest.first, !slug.hasPrefix("-") else { throw CLIError(message: "show requires a <slug>") }
            let json = rest.contains("--json")
            guard let r = try await bundle.store.inventoryRecord(slug: slug) else {
                return ("wiki-inventory: no record '\(slug)'\n", false)
            }
            return (formatShow(r, json: json), true)

        case "save-view":
            let (slug, title, filters) = try parseSaveView(rest)
            _ = try await bundle.store.upsertInventoryView(InventoryViewRow(slug: slug, title: title, filters: filters, updatedAt: now))
            return ("wiki-inventory: saved view '\(slug)'\n", true)

        case "views":
            let views = try await bundle.store.inventoryViews()
            return (formatViews(views, json: rest.contains("--json")), true)

        default:
            throw CLIError(message: "unknown wiki-inventory verb '\(verb)' (expected: list|add|show|save-view|views)")
        }
    }

    // MARK: - pure builders / formatters (hermetically tested)

    static func record(from o: AddOptions, now: Int64, createdAt: Int64) -> InventoryRecordRow {
        InventoryRecordRow(slug: o.slug, kind: o.kind, status: o.status, priority: o.priority, title: o.title,
                           summary: o.summary, nextAction: o.nextAction, tags: o.tags, origin: o.origin,
                           confidence: o.confidence, bodyMd: o.body, createdAt: createdAt, updatedAt: now)
    }

    static func formatList(_ records: [InventoryRecordRow], json: Bool) -> String {
        if json {
            let rows = records.map { r -> [String: Any] in
                ["slug": r.slug, "kind": r.kind, "status": r.status, "priority": r.priority,
                 "title": r.title, "lifecycle": r.lifecycleStatus]
            }
            let obj: [String: Any] = ["count": records.count, "records": rows]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-inventory: \(records.count) record(s)\n"
        for r in records {
            out += String(format: "  %-3@ %-16@ %-10@  %@\n",
                          r.priority as NSString, r.kind as NSString, r.status as NSString,
                          String(r.title.prefix(60)))
        }
        return out
    }

    static func formatShow(_ r: InventoryRecordRow, json: Bool) -> String {
        if json {
            var obj: [String: Any] = ["slug": r.slug, "kind": r.kind, "status": r.status, "priority": r.priority,
                                      "title": r.title, "lifecycle": r.lifecycleStatus,
                                      "createdAt": NSNumber(value: r.createdAt), "updatedAt": NSNumber(value: r.updatedAt)]
            if let s = r.summary { obj["summary"] = s }
            if let n = r.nextAction { obj["nextAction"] = n }
            if let t = r.tags { obj["tags"] = t }
            if let o = r.origin { obj["origin"] = o }
            if let c = r.confidence { obj["confidence"] = c }
            if let b = r.bodyMd { obj["body"] = b }
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "\(r.slug)  [\(r.kind) · \(r.status) · \(r.priority)]\n  \(r.title)\n"
        if let s = r.summary { out += "  summary: \(s)\n" }
        if let n = r.nextAction { out += "  next: \(n)\n" }
        if let t = r.tags { out += "  tags: \(t)\n" }
        return out
    }

    static func formatViews(_ views: [InventoryViewRow], json: Bool) -> String {
        if json {
            let rows = views.map { ["slug": $0.slug, "title": $0.title, "filters": $0.filters as Any].compactMapValues { $0 } }
            let d = (try? JSONSerialization.data(withJSONObject: ["count": views.count, "views": rows],
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-inventory views: \(views.count)\n"
        for v in views { out += "  \(v.slug)  \(v.title)\n" }
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
            case "--slug": o.slug = try val("--slug")
            case "--kind": o.kind = try val("--kind")
            case "--title": o.title = try val("--title")
            case "--status": o.status = try val("--status")
            case "--priority": o.priority = try val("--priority")
            case "--summary": o.summary = try val("--summary")
            case "--next-action": o.nextAction = try val("--next-action")
            case "--tags": o.tags = try val("--tags")
            case "--origin": o.origin = try val("--origin")
            case "--confidence": o.confidence = try val("--confidence")
            case "--body": o.body = try val("--body")
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        guard !o.slug.isEmpty else { throw CLIError(message: "add requires --slug") }
        guard !o.kind.isEmpty else { throw CLIError(message: "add requires --kind") }
        guard !o.title.isEmpty else { throw CLIError(message: "add requires --title") }
        guard kinds.contains(o.kind) else { throw CLIError(message: "--kind must be one of: \(kinds.sorted().joined(separator: "|"))") }
        guard statuses.contains(o.status) else { throw CLIError(message: "--status must be one of: \(statuses.sorted().joined(separator: "|"))") }
        guard o.priority.count == 2, o.priority.first == "p", let n = Int(o.priority.dropFirst()), (0...4).contains(n) else {
            throw CLIError(message: "--priority must be p0..p4")
        }
        return o
    }

    static func parseList(_ args: [String]) throws -> ListOptions {
        var o = ListOptions(); var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--kind": o.kind = try val("--kind")
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

    static func parseSaveView(_ args: [String]) throws -> (slug: String, title: String, filters: String?) {
        var slug = "", title = "", filters: String?; var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--slug": slug = try val("--slug")
            case "--title": title = try val("--title")
            case "--filters": filters = try val("--filters")
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        guard !slug.isEmpty, !title.isEmpty else { throw CLIError(message: "save-view requires --slug and --title") }
        if let f = filters, (try? JSONSerialization.jsonObject(with: Data(f.utf8))) == nil {
            throw CLIError(message: "--filters must be valid JSON")
        }
        return (slug, title, filters)
    }
}
