import Foundation

/// Feature gating (port of `isWorkflowToolEnabled`/`v0`). codex-swift has no
/// plan/statsig concept, so the policy is **default-on** unless explicitly
/// disabled via env `CODEX_WORKFLOWS_DISABLE` or the `workflows` feature flag.
public enum WorkflowGating {
    public static func isEnabled(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let v = env["CODEX_WORKFLOWS_DISABLE"], ["1", "true", "yes", "on"].contains(v.lowercased()) {
            return false
        }
        if let v = env["CODEX_FEATURE_WORKFLOWS"] {
            return ["1", "true", "yes", "on"].contains(v.lowercased())
        }
        return true
    }

    /// Whether the five remote-only built-ins (autopilot/bugfix/dashboard/docs/
    /// investigate) are registered (port of the `CLAUDE_CODE_REMOTE` gate).
    public static func remoteBuiltinsEnabled(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let v = env["CODEX_WORKFLOWS_REMOTE"] { return ["1", "true", "yes", "on"].contains(v.lowercased()) }
        return false
    }
}

/// Built-in ∪ disk discovery with precedence project > user > admin > built-in
/// (first-write-wins by name). Mirrors the `SkillsDiscovery` structure.
public struct WorkflowsDiscovery: Sendable {
    public init() {}

    public func discover(codexHome: String,
                         cwds: [String] = [FileManager.default.currentDirectoryPath],
                         home: String = NSHomeDirectory(),
                         projectRootMarkers: [String] = [".git"],
                         env: [String: String] = ProcessInfo.processInfo.environment) -> [WorkflowDef] {
        var byName: [String: WorkflowDef] = [:]
        func add(_ defs: [WorkflowDef]) {
            for d in defs where byName[d.name] == nil { byName[d.name] = d }
        }
        // precedence high→low (first write wins)
        for cwd in cwds {
            for root in projectRoots(cwd: cwd, markers: projectRootMarkers) {
                add(scan(root + "/.agents/workflows", source: .projectSettings))
            }
        }
        add(scan(home + "/.agents/workflows", source: .userSettings))
        add(scan(codexHome + "/workflows", source: .admin))
        add(BuiltinWorkflows.all(env: env))
        return Array(byName.values).sorted { $0.name < $1.name }
    }

    public func resolve(name: String, codexHome: String,
                        cwds: [String] = [FileManager.default.currentDirectoryPath]) -> WorkflowDef? {
        discover(codexHome: codexHome, cwds: cwds).first { $0.name == name }
    }

    private func projectRoots(cwd: String, markers: [String]) -> [String] {
        var roots: [String] = [cwd]
        var dir = cwd
        let fm = FileManager.default
        while dir != "/" && !dir.isEmpty {
            for m in markers where fm.fileExists(atPath: dir + "/" + m) {
                if !roots.contains(dir) { roots.append(dir) }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return roots
    }

    private func scan(_ root: String, source: WorkflowDef.Source) -> [WorkflowDef] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [WorkflowDef] = []
        for e in entries.sorted() where e.hasSuffix(".js") {
            let path = root + "/" + e
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size <= WF.maxScriptBytes,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            guard let meta = try? WorkflowMeta.parse(text) else { continue }
            out.append(WorkflowDef(source: source, name: meta.name, description: meta.description,
                                   whenToUse: meta.whenToUse, phases: meta.phases,
                                   script: text, filePath: path))
        }
        return out
    }
}
