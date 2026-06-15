import Foundation
import MemoryStore

// Grounding-citation lint (§5.C) — the trust mechanism for Plan/Output artifacts: every
// decision/phase (a `## ` section) must carry a `Wiki grounding:` citation that resolves
// to a REAL synthesis page ([[slug]]) or claim (claim:N). A plan whose decisions cite
// nothing — or cite ids that don't exist — fails the lint, so an ungrounded plan can be
// refused at write time (strict mode).

struct GroundingViolation: Sendable, Equatable {
    enum Kind: String, Sendable { case ungroundedSection, danglingSlug, danglingClaim }
    var kind: Kind
    var detail: String
}

enum WikiGroundingLint {
    /// All `[[slug]]` and `claim:N` references anywhere in the body.
    static func citations(in body: String) -> (slugs: [String], claims: [Int64]) {
        var slugs: [String] = []
        var rest = Substring(body)
        while let open = rest.range(of: "[[") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "]]") else { break }
            let slug = String(afterOpen[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !slug.isEmpty { slugs.append(slug) }
            rest = afterOpen[close.upperBound...]
        }
        var claims: [Int64] = []
        // tokenize on non-[alnum:] so "claim:42" survives as one token.
        for token in body.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == ":") }) {
            if token.hasPrefix("claim:"), let n = Int64(token.dropFirst("claim:".count)) { claims.append(n) }
        }
        return (slugs, claims)
    }

    /// Drop fenced ```code``` blocks so `## ` headings and `Wiki grounding:` lines inside
    /// markdown SAMPLES aren't mistaken for real structure.
    static func stripFences(_ body: String) -> String {
        var out: [String] = []; var inFence = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if !inFence { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Split into `## ` sections (heading, body-text). Preamble before the first `## `
    /// is not a decision section and is not linted.
    static func sections(_ body: String) -> [(heading: String, text: String)] {
        var out: [(String, String)] = []
        var heading: String?; var buf: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## ") {
                if let h = heading { out.append((h, buf.joined(separator: "\n"))) }
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); buf = []
            } else { buf.append(line) }
        }
        if let h = heading { out.append((h, buf.joined(separator: "\n"))) }
        return out
    }

    /// Citations that appear specifically ON a `Wiki grounding:` line within a section —
    /// so a decision is "grounded" only when the grounding line ITSELF cites a real id,
    /// not merely because some unrelated `[[link]]` appears elsewhere in the section.
    static func groundingCitations(inSection text: String) -> (slugs: [String], claims: [Int64]) {
        var slugs: [String] = []; var claims: [Int64] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        where line.lowercased().contains("wiki grounding:") {
            let c = citations(in: line); slugs += c.slugs; claims += c.claims
        }
        return (slugs, claims)
    }

    /// Violations: (1) any citation (outside code fences) to a non-existent slug/claim;
    /// (2) any `## ` section whose `Wiki grounding:` line(s) don't cite ≥1 valid id.
    static func lint(body: String, validSlugs: Set<String>, validClaims: Set<Int64>) -> [GroundingViolation] {
        var violations: [GroundingViolation] = []
        let stripped = stripFences(body)
        let all = citations(in: stripped)
        for s in Set(all.slugs) where !validSlugs.contains(s) {
            violations.append(GroundingViolation(kind: .danglingSlug, detail: s))
        }
        for c in Set(all.claims) where !validClaims.contains(c) {
            violations.append(GroundingViolation(kind: .danglingClaim, detail: "claim:\(c)"))
        }
        for (heading, text) in sections(stripped) {
            let g = groundingCitations(inSection: text)
            let resolves = g.slugs.contains(where: validSlugs.contains) || g.claims.contains(where: validClaims.contains)
            if !resolves {
                violations.append(GroundingViolation(kind: .ungroundedSection, detail: heading))
            }
        }
        return violations.sorted { ($0.kind.rawValue, $0.detail) < ($1.kind.rawValue, $1.detail) }
    }
}

/// `codex-memory wiki-plan file ...` / `wiki-output file ...` — file a provided markdown
/// body as a durable `synthesis` row (category=plan|report|… + format + output_type),
/// linking its grounding citations to real claims. Plans are grounding-lint-enforced:
/// `--strict` REFUSES an ungrounded plan; otherwise violations are surfaced but the page
/// is still written (a warning). The frontier GENERATION of plan/report bodies reuses the
/// research/compile frontier infra and is tracked separately; this files + grounds the body.
enum CodexMemoryWikiArtifact {
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }
    static let planFormats: Set<String> = ["rfc", "adr", "spec", "roadmap"]
    static let outputTypes: Set<String> = ["report", "deck", "study-guide", "playbook", "timeline", "glossary", "comparison", "digest"]

    /// Shared filing core: lint (for plans) → write body file → upsert synthesis row →
    /// link cited claims. Returns (output, ok). `category` is "plan" or an output type.
    /// A filesystem-safe page identifier: lowercase alnum + `-`/`_`, ≤128 chars. Blocks
    /// `/`, `..`, leading-dot — so a `--slug` can never escape `wiki/<category>/`.
    static func isSafeSlug(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 128 else { return false }
        return s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    static func file(store: MemoryStore, vaultRoot: String, now: Int64,
                     slug: String, title: String, category: String, format: String?, outputType: String?,
                     body: String, strict: Bool, enforceGrounding: Bool, project: String? = nil) async throws -> (String, Bool) {
        // Path-traversal guard: the slug is the on-disk filename — never let it escape.
        guard isSafeSlug(slug) else {
            return ("wiki-\(category): REFUSED — unsafe slug '\(slug)' (use [a-z0-9-_], no slashes/dots)\n", false)
        }
        // §5.C Project pre-flight gate: a `--project` must name a REGISTERED project (one
        // whose WHY.md is written) before any artifact can be filed into it. This is the
        // "state why first" trust mechanism — checked BEFORE we write anything.
        if let proj = project {
            guard WikiProject.isSafeSlug(proj) else {
                return ("wiki-\(category): REFUSED — unsafe project slug '\(proj)'\n", false)
            }
            guard WikiProject.isRegistered(vaultRoot, proj) else {
                return ("wiki-\(category): REFUSED — project '\(proj)' has no WHY.md "
                    + "(run `wiki-project create \(proj) --why \"…\"` first)\n", false)
            }
        }
        // Resolve grounding citations against the store by DIRECT lookup of each cited id
        // (no bulk fetch-and-cap — a real-but-stale page beyond a LIMIT must still resolve).
        let cited = WikiGroundingLint.citations(in: WikiGroundingLint.stripFences(body))
        var validSlugs = Set<String>()
        for s in Set(cited.slugs) { if (try? await store.synthesis(slug: s)) != nil { validSlugs.insert(s) } }
        var validClaims = Set<Int64>()
        var citedClaimIDs: [Int64] = []
        for cid in Set(cited.claims) {
            if (try? await store.claim(id: cid)) != nil { validClaims.insert(cid); citedClaimIDs.append(cid) }
        }
        if enforceGrounding {
            let violations = WikiGroundingLint.lint(body: body, validSlugs: validSlugs, validClaims: validClaims)
            if !violations.isEmpty {
                let summary = violations.map { "\($0.kind.rawValue): \($0.detail)" }.joined(separator: "; ")
                if strict {
                    return ("wiki-\(category): REFUSED — ungrounded (\(violations.count)): \(summary)\n", false)
                }
                // lint mode: warn but proceed.
                let id = try await write(store: store, vaultRoot: vaultRoot, now: now, slug: slug, title: title,
                                         category: category, format: format, outputType: outputType, body: body,
                                         claims: citedClaimIDs)
                let routed = routeToProject(vaultRoot: vaultRoot, project: project, category: category,
                                            slug: slug, title: title, body: body, now: now)
                return ("wiki-\(category): filed \(slug) (id \(id))\(routed) — WARN ungrounded (\(violations.count)): \(summary)\n", true)
            }
        }
        let id = try await write(store: store, vaultRoot: vaultRoot, now: now, slug: slug, title: title,
                                 category: category, format: format, outputType: outputType, body: body,
                                 claims: citedClaimIDs)
        let routed = routeToProject(vaultRoot: vaultRoot, project: project, category: category,
                                    slug: slug, title: title, body: body, now: now)
        return ("wiki-\(category): filed \(slug) (id \(id))\(routed)\n", true)
    }

    /// Route a filed artifact into its project folder (when `--project` is set). Best-effort:
    /// the durable synthesis row is the source of truth, so a routing hiccup must not fail the
    /// file. Returns a message fragment for the CLI output (empty when no project).
    static func routeToProject(vaultRoot: String, project: String?, category: String,
                               slug: String, title: String, body: String, now: Int64) -> String {
        guard let proj = project else { return "" }
        guard let path = try? WikiProject.route(vaultRoot: vaultRoot, slug: proj, category: category,
                                                artifactSlug: slug, title: title, body: body, now: now) else {
            return " (project routing failed)"
        }
        return " → project:\(proj) (\((path as NSString).lastPathComponent))"
    }

    /// Write the body to `<vaultRoot>/wiki/<category>/<slug>.md` (file failures throw
    /// BEFORE the row is registered, so no row points at a missing body), upsert the
    /// synthesis row, and link the cited claims.
    @discardableResult
    static func write(store: MemoryStore, vaultRoot: String, now: Int64,
                      slug: String, title: String, category: String, format: String?, outputType: String?,
                      body: String, claims: [Int64]) async throws -> Int64 {
        let dir = (vaultRoot as NSString).appendingPathComponent("wiki/" + category)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(slug + ".md")
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        let id = try await store.upsertSynthesis(SynthesisRow(
            slug: slug, category: category, title: title, bodyPath: path, confidence: "medium",
            volatility: .warm, verifiedAt: now, createdAt: now, updatedAt: now, format: format,
            generatedAt: now, outputType: outputType))
        for cid in claims { try? await store.linkSynthesisClaim(synthesis: id, claim: cid) }
        return id
    }

    // MARK: - CLI entry points

    static func runPlan(args: [String]) async throws -> (output: String, ok: Bool) {
        guard args.first == "file" else { throw CLIError(message: "wiki-plan requires the 'file' verb") }
        let o = try parse(Array(args.dropFirst()), formats: planFormats, formatFlag: "--format")
        guard let format = o.format, planFormats.contains(format) else {
            throw CLIError(message: "wiki-plan requires --format (\(planFormats.sorted().joined(separator: "|")))")
        }
        let bundle = try await CodexMemoryRun.assemble()
        let vaultRoot = (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent
        return try await file(store: bundle.store, vaultRoot: vaultRoot, now: Int64(Date().timeIntervalSince1970),
                              slug: o.slug, title: o.title, category: "plan", format: format, outputType: nil,
                              body: o.body, strict: o.strict, enforceGrounding: true, project: o.project)
    }

    static func runOutput(args: [String]) async throws -> (output: String, ok: Bool) {
        guard args.first == "file" else { throw CLIError(message: "wiki-output requires the 'file' verb") }
        let o = try parse(Array(args.dropFirst()), formats: outputTypes, formatFlag: "--type")
        let type = o.format ?? "report"
        guard outputTypes.contains(type) else {
            throw CLIError(message: "wiki-output --type must be one of: \(outputTypes.sorted().joined(separator: "|"))")
        }
        let bundle = try await CodexMemoryRun.assemble()
        let vaultRoot = (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent
        // Outputs are filed under category=report with output_type=<type>; grounding is
        // surfaced but not enforced (outputs aren't decisions).
        return try await file(store: bundle.store, vaultRoot: vaultRoot, now: Int64(Date().timeIntervalSince1970),
                              slug: o.slug, title: o.title, category: "report", format: nil, outputType: type,
                              body: o.body, strict: false, enforceGrounding: false, project: o.project)
    }

    struct Options { var slug = "", title = "", body = "", strict = false; var format: String?; var project: String? }

    static func parse(_ args: [String], formats: Set<String>, formatFlag: String) throws -> Options {
        var o = Options(); var i = 0
        func val(_ f: String) throws -> String { i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }; return args[i] }
        while i < args.count {
            switch args[i] {
            case "--slug": o.slug = try val("--slug")
            case "--title": o.title = try val("--title")
            case "--body": o.body = try val("--body")
            case "--body-file":
                let p = try val("--body-file")
                guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { throw CLIError(message: "could not read --body-file \(p)") }
                o.body = s
            case "--strict": o.strict = true
            case "--project": o.project = try val("--project")
            case formatFlag: o.format = try val(formatFlag)
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        guard !o.slug.isEmpty else { throw CLIError(message: "file requires --slug") }
        guard isSafeSlug(o.slug) else { throw CLIError(message: "--slug must be [a-z0-9-_] (no slashes/dots/uppercase)") }
        guard !o.title.isEmpty else { throw CLIError(message: "file requires --title") }
        guard !o.body.isEmpty else { throw CLIError(message: "file requires --body or --body-file") }
        return o
    }
}
