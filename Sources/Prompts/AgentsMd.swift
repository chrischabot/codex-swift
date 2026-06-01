import Foundation

/// Faithful port of `codex-rs/core/src/agents_md.rs`.
public struct AgentsMdManager: Sendable {
    public static let DEFAULT_AGENTS_MD_FILENAME = "AGENTS.md"
    public static let LOCAL_AGENTS_MD_FILENAME = "AGENTS.override.md"
    public static let AGENTS_MD_SEPARATOR = "\n\n--- project-doc ---\n\n"
    public static let AGENTS_MD_MAX_BYTES = 32_768  // DEFAULT_PROJECT_DOC_MAX_BYTES (32 KiB)
    public static let DEFAULT_PROJECT_ROOT_MARKERS = [".git"]

    public static let HIERARCHICAL_AGENTS_MESSAGE = #"""
Files called AGENTS.md commonly appear in many places inside a container - at "/", in "~", deep within git repositories, or in any other directory; their location is not limited to version-controlled folders.

Their purpose is to pass along human guidance to you, the agent. Such guidance can include coding standards, explanations of the project layout, steps for building or testing, and even wording that must accompany a GitHub pull-request description produced by the agent; all of it is to be followed.

Each AGENTS.md governs the entire directory that contains it and every child directory beneath that point. Whenever you change a file, you have to comply with every AGENTS.md whose scope covers that file. Naming conventions, stylistic rules and similar directives are restricted to the code that falls inside that scope unless the document explicitly states otherwise.

When two AGENTS.md files disagree, the one located deeper in the directory structure overrides the higher-level file, while instructions given directly in the prompt by the system, developer, or user outrank any AGENTS.md content.
"""#

    public var codexHome: String
    public var cwd: String
    public var configUserInstructions: String?
    public var projectDocMaxBytes: Int
    public var projectRootMarkers: [String]
    public var fallbackFilenames: [String]
    public var childAgentsMdEnabled: Bool

    public init(codexHome: String, cwd: String,
                configUserInstructions: String? = nil,
                projectDocMaxBytes: Int = AgentsMdManager.AGENTS_MD_MAX_BYTES,
                projectRootMarkers: [String] = AgentsMdManager.DEFAULT_PROJECT_ROOT_MARKERS,
                fallbackFilenames: [String] = [],
                childAgentsMdEnabled: Bool = false) {
        self.codexHome = codexHome; self.cwd = cwd
        self.configUserInstructions = configUserInstructions
        self.projectDocMaxBytes = projectDocMaxBytes
        self.projectRootMarkers = projectRootMarkers
        self.fallbackFilenames = fallbackFilenames
        self.childAgentsMdEnabled = childAgentsMdEnabled
    }

    private func candidateFilenames() -> [String] {
        var names = [Self.LOCAL_AGENTS_MD_FILENAME, Self.DEFAULT_AGENTS_MD_FILENAME]
        for c in fallbackFilenames where !c.isEmpty && !names.contains(c) { names.append(c) }
        return names
    }

    /// `load_global_instructions` — `$CODEX_HOME` override then default.
    public func loadGlobalInstructions() -> (contents: String, path: String)? {
        for candidate in [Self.LOCAL_AGENTS_MD_FILENAME, Self.DEFAULT_AGENTS_MD_FILENAME] {
            let path = (codexHome as NSString).appendingPathComponent(candidate)
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return (trimmed, path) }
            }
        }
        return nil
    }

    /// `agents_md_paths` — project-root walk from cwd; root markers default
    /// `.git`; collect from root → cwd inclusive.
    public func agentsMdPaths() -> [String] {
        if projectDocMaxBytes == 0 { return [] }
        let fm = FileManager.default
        // Upstream `agents_md.rs` runs `dunce::canonicalize` (symlink-resolving)
        // on the cwd BEFORE the project-root ancestor walk, so markers and
        // AGENTS.md files are discovered along the REAL path. `standardizingPath`
        // alone only normalizes `.`/`..`/`~` and does NOT resolve symlinks;
        // resolve symlinks first, then standardize the relative components.
        let dir = ((cwd as NSString).resolvingSymlinksInPath as NSString).standardizingPath
        var projectRoot: String?
        if !projectRootMarkers.isEmpty {
            var cursor = dir
            while true {
                for marker in projectRootMarkers {
                    if fm.fileExists(atPath: (cursor as NSString).appendingPathComponent(marker)) {
                        projectRoot = cursor; break
                    }
                }
                if projectRoot != nil { break }
                let parent = (cursor as NSString).deletingLastPathComponent
                if parent == cursor || parent.isEmpty { break }
                cursor = parent
            }
        }
        var searchDirs: [String]
        if let root = projectRoot {
            var dirs: [String] = []
            var cursor = dir
            while true {
                dirs.append(cursor)
                if cursor == root { break }
                let parent = (cursor as NSString).deletingLastPathComponent
                if parent == cursor || parent.isEmpty { break }
                cursor = parent
            }
            searchDirs = dirs.reversed()
        } else {
            searchDirs = [dir]
        }
        var found: [String] = []
        let names = candidateFilenames()
        for d in searchDirs {
            for name in names {
                let candidate = (d as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                    found.append(candidate); break
                }
            }
        }
        return found
    }

    private func readAgentsMd() -> String? {
        let maxTotal = projectDocMaxBytes
        if maxTotal == 0 { return nil }
        let paths = agentsMdPaths()
        if paths.isEmpty { return nil }
        var remaining = maxTotal
        var parts: [String] = []
        for p in paths {
            if remaining == 0 { break }
            guard var data = FileManager.default.contents(atPath: p) else { continue }
            if data.count > remaining { data = data.prefix(remaining) }
            let text = String(decoding: data, as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(text)
                remaining = Swift.max(0, remaining - data.count)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// `user_instructions_with_fs` — config instructions + AGENTS.md docs +
    /// optional hierarchical message.
    public func userInstructions() -> String? {
        var output = ""
        if let instructions = configUserInstructions { output += instructions }
        if let docs = readAgentsMd() {
            if !output.isEmpty { output += Self.AGENTS_MD_SEPARATOR }
            output += docs
        }
        if childAgentsMdEnabled {
            if !output.isEmpty { output += "\n\n" }
            output += Self.HIERARCHICAL_AGENTS_MESSAGE
        }
        return output.isEmpty ? nil : output
    }

    /// `instruction_sources` — global override path + discovered AGENTS.md.
    public func instructionSources() -> [String] {
        var paths: [String] = []
        if let g = loadGlobalInstructions() { paths.append(g.path) }
        paths.append(contentsOf: agentsMdPaths())
        return paths
    }
}