import Foundation

/// A discovered skill (Codex `core-skills`). `path` is the skill directory so
/// the model can read the full SKILL.md on demand.
public struct SkillRecord: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var path: String
    public init(name: String, description: String, path: String) {
        self.name = name; self.description = description; self.path = path
    }
}

/// Discovers skills from the canonical Codex roots (upstream
/// `core-skills/src/loader.rs`):
///
/// 1. **Admin** — `$CODEX_HOME/skills/<id>/SKILL.md`
/// 2. **User** — `$HOME/.agents/skills/<id>/SKILL.md`
/// 3. **Repo** — for each directory walked from cwd up to the project root
///    (anchored by `projectRootMarkers`, default `[".git"]`):
///    `<dir>/.agents/skills/<id>/SKILL.md`
/// 4. **Legacy** — `<cwd>/.codex/skills/<id>/SKILL.md` (kept for backward
///    compatibility with pre-`.agents/skills` Swift sessions; not in upstream).
///
/// Frontmatter is the leading `---`-delimited YAML block; `name`/`description`
/// are read from it (falling back to the directory name / first non-empty body
/// line). Pure, `Sendable`, dependency-free.
public struct SkillsDiscovery: Sendable {
    public init() {}

    /// Discover skills. `cwds` are session workspaces (we walk up from each
    /// to find `.agents/skills` directories). `home` defaults to the process
    /// `$HOME`; pass an override for hermetic tests. `projectRootMarkers`
    /// anchors the upward walk (empty = no walk; nil = `[".git"]`).
    public func discover(codexHome: String,
                         cwds: [String],
                         home: String? = nil,
                         projectRootMarkers: [String]? = nil) -> [SkillRecord] {
        let markers = projectRootMarkers ?? [".git"]
        let homeDir = home ?? ProcessInfo.processInfo.environment["HOME"]

        // Upstream priority order (Admin → User → Repo → Legacy). De-dup is by
        // skill name, first-write-wins, so this matches upstream's
        // `prompt_scope_rank` precedence.
        var roots: [String] = []
        roots.append(codexHome + "/skills")
        if let h = homeDir, !h.isEmpty {
            roots.append(h + "/.agents/skills")
        }
        for c in cwds {
            roots.append(contentsOf: agentsSkillsRoots(forCwd: c, markers: markers))
        }
        for c in cwds {
            roots.append(c + "/.codex/skills")
        }
        var seen = Set<String>()
        var seenRoots = Set<String>()
        var out: [SkillRecord] = []
        for root in roots {
            // Dedup repeated paths (same dir appears as both repo root and
            // cwd when there's no marker, etc.).
            let canon = (root as NSString).standardizingPath
            if !seenRoots.insert(canon).inserted { continue }
            for rec in scanRoot(root) where !seen.contains(rec.name) {
                seen.insert(rec.name)
                out.append(rec)
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Walk from `cwd` upward to the project root (first ancestor containing
    /// any `markers` entry; default `[".git"]`) and emit each
    /// `<dir>/.agents/skills` candidate, ordered root-first → cwd-last to
    /// match upstream `dirs_between_project_root_and_cwd` (so deeper repo
    /// roots can override shallower ones when scanning).
    private func agentsSkillsRoots(forCwd cwd: String, markers: [String]) -> [String] {
        if markers.isEmpty {
            return [cwd + "/.agents/skills"]
        }
        let fm = FileManager.default
        let start = (cwd as NSString).standardizingPath
        var projectRoot: String?
        var cursor = start
        while true {
            for marker in markers {
                let candidate = (cursor as NSString).appendingPathComponent(marker)
                if fm.fileExists(atPath: candidate) {
                    projectRoot = cursor; break
                }
            }
            if projectRoot != nil { break }
            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor || parent.isEmpty { break }
            cursor = parent
        }
        guard let root = projectRoot else {
            return [start + "/.agents/skills"]
        }
        var dirs: [String] = []
        cursor = start
        while true {
            dirs.append(cursor)
            if cursor == root { break }
            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor || parent.isEmpty { break }
            cursor = parent
        }
        return dirs.reversed().map { $0 + "/.agents/skills" }
    }

    private func scanRoot(_ root: String) -> [SkillRecord] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var recs: [SkillRecord] = []
        for entry in entries.sorted() {
            let dir = root + "/" + entry
            let skillFile = dir + "/SKILL.md"
            guard fm.fileExists(atPath: skillFile),
                  let body = try? String(contentsOfFile: skillFile, encoding: .utf8) else {
                continue
            }
            let fm2 = parseFrontmatter(body)
            let name = fm2["name"] ?? entry
            let desc = fm2["description"] ?? firstBodyLine(body) ?? ""
            recs.append(SkillRecord(name: name, description: desc, path: dir))
        }
        return recs
    }

    /// Parse a leading `---\n ... \n---` YAML-ish frontmatter block into
    /// `key: value` pairs (quotes trimmed). Flat scalars are the primary
    /// shape, plus YAML block scalars (`key: |` literal and `key: >` folded)
    /// where subsequent indented lines are folded into the value — this is
    /// the natural way to write multi-line skill descriptions and was a real
    /// stumbling block in live runs (a `description: |` block silently
    /// became `description = "|"`, so the model never saw the rules).
    func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        var idx = 1
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { idx += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if (val == "|" || val == ">"
                || val.hasPrefix("|-") || val.hasPrefix(">-")
                || val.hasPrefix("|+") || val.hasPrefix(">+")) {
                let folded = val.hasPrefix(">")
                var body: [String] = []
                var j = idx + 1
                while j < lines.count {
                    let raw = lines[j]
                    let bodyTrim = raw.trimmingCharacters(in: .whitespaces)
                    if bodyTrim == "---" { break }
                    // Stop on first non-indented, non-empty line (next key).
                    let leading = raw.prefix(while: { $0 == " " || $0 == "\t" })
                    if leading.isEmpty && !bodyTrim.isEmpty { break }
                    body.append(String(raw.drop(while: { $0 == " " || $0 == "\t" })))
                    j += 1
                }
                val = folded
                    ? body.joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    : body.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespaces)
                idx = j
            } else {
                if (val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2)
                    || (val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2) {
                    val = String(val.dropFirst().dropLast())
                }
                idx += 1
            }
            if !key.isEmpty { result[key] = val }
        }
        return result
    }

    private func firstBodyLine(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inFront = false
        var started = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" {
                if !started { inFront = true; started = true; continue }
                if inFront { inFront = false; continue }
            }
            if inFront { continue }
            if t.isEmpty || t.hasPrefix("#") { continue }
            return t
        }
        return nil
    }
}