import Foundation
import MemoryStore

// Project scope (§5.C Project) — a filesystem-backed registry under
// `<vaultRoot>/output/projects/<slug>/`. The folder IS the registry: a project is
// "registered" iff its `WHY.md` exists and is non-empty. That single file is also
// the **pre-flight gate** — `wiki-output`/`wiki-plan --project <slug>` REFUSES to
// file into a project until its WHY.md is written (you must state *why* before you
// produce artifacts). Filed artifacts are routed into the project folder and
// recorded in `INDEX.md` (folder membership = the `project:<slug>` tag — no schema
// change, fully durable + self-describing).
enum WikiProject {
    struct ProjectError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    /// One registered project (folder with a non-empty WHY.md).
    struct Summary: Sendable, Equatable {
        var slug: String
        var why: String          // first non-empty line of WHY.md, trimmed
        var artifactCount: Int    // routed artifacts (excludes WHY.md / INDEX.md)
    }

    // MARK: paths

    static func root(_ vaultRoot: String) -> String {
        (vaultRoot as NSString).appendingPathComponent("output/projects")
    }
    static func dir(_ vaultRoot: String, _ slug: String) -> String {
        (root(vaultRoot) as NSString).appendingPathComponent(slug)
    }
    static func whyPath(_ vaultRoot: String, _ slug: String) -> String {
        (dir(vaultRoot, slug) as NSString).appendingPathComponent("WHY.md")
    }
    static func indexPath(_ vaultRoot: String, _ slug: String) -> String {
        (dir(vaultRoot, slug) as NSString).appendingPathComponent("INDEX.md")
    }

    /// Same slug rules as artifacts: lowercase alnum + `-`/`_`, ≤128, no slashes/dots —
    /// so a project slug can never escape `output/projects/`.
    static func isSafeSlug(_ s: String) -> Bool { CodexMemoryWikiArtifact.isSafeSlug(s) }

    // MARK: registry

    /// A project is registered iff its WHY.md exists with non-whitespace content. This is
    /// BOTH the membership test and the pre-flight gate the artifact generators consult.
    static func isRegistered(_ vaultRoot: String, _ slug: String) -> Bool {
        guard let s = try? String(contentsOfFile: whyPath(vaultRoot, slug), encoding: .utf8) else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Create (or, with `force`, overwrite) a project's WHY.md. Refuses to clobber an
    /// existing non-empty rationale unless forced.
    @discardableResult
    static func create(vaultRoot: String, slug: String, why: String, force: Bool) throws -> String {
        guard isSafeSlug(slug) else { throw ProjectError(message: "unsafe project slug '\(slug)' (use [a-z0-9-_], no slashes/dots)") }
        let trimmed = why.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectError(message: "a project needs a non-empty --why (state the goal)") }
        if isRegistered(vaultRoot, slug) && !force {
            throw ProjectError(message: "project '\(slug)' already has a WHY.md (pass --force to overwrite)")
        }
        let d = dir(vaultRoot, slug)
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        // A small header so the file is self-explanatory when opened in the vault.
        let doc = "# Why: \(slug)\n\n\(trimmed)\n"
        try doc.write(toFile: whyPath(vaultRoot, slug), atomically: true, encoding: .utf8)
        return whyPath(vaultRoot, slug)
    }

    /// Enumerate registered projects (subdirs of output/projects/ with a non-empty WHY.md).
    static func list(_ vaultRoot: String) -> [Summary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root(vaultRoot)) else { return [] }
        var out: [Summary] = []
        for slug in entries.sorted() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir(vaultRoot, slug), isDirectory: &isDir), isDir.boolValue else { continue }
            guard isRegistered(vaultRoot, slug) else { continue }
            out.append(Summary(slug: slug, why: whySummary(vaultRoot, slug), artifactCount: artifactCount(vaultRoot, slug)))
        }
        return out
    }

    /// First non-empty, non-heading line of WHY.md (the one-line goal), capped.
    static func whySummary(_ vaultRoot: String, _ slug: String) -> String {
        guard let s = try? String(contentsOfFile: whyPath(vaultRoot, slug), encoding: .utf8) else { return "" }
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return String(line.prefix(200))
        }
        return ""
    }

    /// Count routed artifacts in the project folder (everything but WHY.md / INDEX.md).
    static func artifactCount(_ vaultRoot: String, _ slug: String) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir(vaultRoot, slug)) else { return 0 }
        return entries.filter { $0.hasSuffix(".md") && $0 != "WHY.md" && $0 != "INDEX.md" }.count
    }

    // MARK: routing

    /// Route a filed artifact INTO the project folder and append it to INDEX.md. Both
    /// `category` and `artifactSlug` are already validated upstream (known category +
    /// isSafeSlug), so the path is traversal-safe. Returns the routed path.
    @discardableResult
    static func route(vaultRoot: String, slug: String, category: String,
                      artifactSlug: String, title: String, body: String, now: Int64) throws -> String {
        let d = dir(vaultRoot, slug)
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let fileName = "\(category)-\(artifactSlug).md"
        let path = (d as NSString).appendingPathComponent(fileName)
        // Stamp the project tag in the routed copy so the file is self-describing.
        let stamped = "<!-- project:\(slug) -->\n" + body
        try stamped.write(toFile: path, atomically: true, encoding: .utf8)
        appendIndex(vaultRoot: vaultRoot, slug: slug, line: "- [\(isoDay(now))] \(category): \(fileName) — \(title)")
        return path
    }

    /// Append a line to the project INDEX.md (best-effort; a routed artifact is the
    /// source of truth, the index is a convenience log).
    static func appendIndex(vaultRoot: String, slug: String, line: String) {
        let p = indexPath(vaultRoot, slug)
        let existing = (try? String(contentsOfFile: p, encoding: .utf8)) ?? "# \(slug) — artifacts\n\n"
        try? (existing + line + "\n").write(toFile: p, atomically: true, encoding: .utf8)
    }

    /// Deterministic UTC `YYYY-MM-DD` (no locale/timezone drift).
    static func isoDay(_ epochSeconds: Int64) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// `codex-memory wiki-project <verb>` — manage project scopes.
///   list [--json]                                 registered projects + artifact counts
///   create <slug> --why "…" | --why-file <path>   write the WHY.md (the pre-flight gate)
///   show <slug> [--json]                           WHY + routed-artifact index
enum CodexMemoryWikiProject {
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        guard let verb = args.first else { throw CLIError(message: "wiki-project needs a verb: list|create|show") }
        let rest = Array(args.dropFirst())
        let vaultRoot = (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent

        switch verb {
        case "list":
            let projects = WikiProject.list(vaultRoot)
            if rest.contains("--json") {
                let arr = projects.map { ["slug": $0.slug, "why": $0.why, "artifacts": $0.artifactCount] as [String: Any] }
                return (jsonLine(["projects": arr, "count": projects.count]), true)
            }
            if projects.isEmpty { return ("no projects (create one: wiki-project create <slug> --why \"…\")\n", true) }
            var out = "\(projects.count) project(s):\n"
            for p in projects { out += "  \(p.slug.padding(toLength: 24, withPad: " ", startingAt: 0)) \(p.artifactCount) artifact(s)  — \(p.why)\n" }
            return (out, true)

        case "create":
            let (slug, why, force) = try parseCreate(rest)
            let path = try WikiProject.create(vaultRoot: vaultRoot, slug: slug, why: why, force: force)
            return ("created project '\(slug)' — WHY.md at \(path)\n", true)

        case "show":
            guard let slug = rest.first(where: { !$0.hasPrefix("-") }) else { throw CLIError(message: "wiki-project show needs a <slug>") }
            guard WikiProject.isSafeSlug(slug) else { throw CLIError(message: "unsafe project slug '\(slug)'") }
            guard WikiProject.isRegistered(vaultRoot, slug) else {
                return ("project '\(slug)' not found (no non-empty WHY.md)\n", false)
            }
            let why = (try? String(contentsOfFile: WikiProject.whyPath(vaultRoot, slug), encoding: .utf8)) ?? ""
            let index = (try? String(contentsOfFile: WikiProject.indexPath(vaultRoot, slug), encoding: .utf8)) ?? "(no artifacts yet)\n"
            if rest.contains("--json") {
                return (jsonLine(["slug": slug, "why": why, "artifacts": WikiProject.artifactCount(vaultRoot, slug)]), true)
            }
            return ("project: \(slug)\n\n\(why)\n\n— artifacts —\n\(index)", true)

        default:
            throw CLIError(message: "unknown wiki-project verb '\(verb)'")
        }
    }

    static func parseCreate(_ args: [String]) throws -> (slug: String, why: String, force: Bool) {
        var slug = ""; var why = ""; var force = false; var i = 0
        func val(_ f: String) throws -> String { i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }; return args[i] }
        while i < args.count {
            switch args[i] {
            case "--why": why = try val("--why")
            case "--why-file":
                let p = try val("--why-file")
                guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { throw CLIError(message: "could not read --why-file \(p)") }
                why = s
            case "--force": force = true
            default:
                if args[i].hasPrefix("-") { throw CLIError(message: "unknown flag \(args[i])") }
                slug = args[i]
            }
            i += 1
        }
        guard !slug.isEmpty else { throw CLIError(message: "wiki-project create needs a <slug>") }
        guard !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "wiki-project create needs --why \"…\" (or --why-file) — state the goal first")
        }
        return (slug, why, force)
    }

    static func jsonLine(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self) + "\n"
    }
}
