import Foundation

public enum BenchError: Error, CustomStringConvertible {
    case catalogNotFound(String)
    case taskNotFound(String)
    case malformedTask(String, String)
    case runtimeUnavailable(String)
    case process(String, Int32, String)

    public var description: String {
        switch self {
        case .catalogNotFound(let p): return "deep-swe task catalog not found at \(p) (set CODEX_BENCH_TASKS or run from the repo root)"
        case .taskNotFound(let id): return "no such task: \(id)"
        case .malformedTask(let id, let why): return "task \(id) is malformed: \(why)"
        case .runtimeUnavailable(let why): return "container runtime unavailable: \(why)"
        case .process(let cmd, let code, let tail): return "`\(cmd)` failed (exit \(code)): \(tail)"
        }
    }
}

/// Loads and indexes the vendored deep-swe task suite.
public struct TaskCatalog: Sendable {
    public let root: URL            // .../Benchmarks/deep-swe
    public let tasks: [TaskSpec]
    private let byId: [String: TaskSpec]

    /// Resolve the catalog root, preferring `CODEX_BENCH_TASKS`, then
    /// `<cwd>/Benchmarks/deep-swe`, then walking up from the current directory
    /// to find a `Benchmarks/deep-swe` (so the CLI works from subdirectories).
    public static func defaultRoot(env: [String: String] = ProcessInfo.processInfo.environment,
                                   cwd: String = FileManager.default.currentDirectoryPath) -> URL? {
        if let explicit = env["CODEX_BENCH_TASKS"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Benchmarks/deep-swe")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("tasks").path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        let tasksDir = root.appendingPathComponent("tasks")
        guard fm.fileExists(atPath: tasksDir.path) else {
            throw BenchError.catalogNotFound(tasksDir.path)
        }

        // The manifest carries `repo` (owner/name), which task.toml lacks.
        var repoById: [String: String] = [:]
        let manifestURL = tasksDir.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["tasks"] as? [[String: Any]] {
            for t in arr {
                if let tid = t["task_id"] as? String { repoById[tid] = t["repo"] as? String ?? "" }
            }
        }

        var loaded: [TaskSpec] = []
        let entries = (try? fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let tomlPath = entry.appendingPathComponent("task.toml").path
            guard fm.fileExists(atPath: tomlPath) else { continue }
            do {
                loaded.append(try Self.loadTask(dir: entry,
                                                repo: repoById[entry.lastPathComponent] ?? ""))
            } catch {
                // A single bad task shouldn't sink the whole catalog; surface via stderr.
                FileHandle.standardError.write(Data("warning: skipping \(entry.lastPathComponent): \(error)\n".utf8))
            }
        }
        self.tasks = loaded
        self.byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    }

    private static func loadTask(dir: URL, repo: String) throws -> TaskSpec {
        let id = dir.lastPathComponent
        let toml = try MiniTOML(contentsOfFile: dir.appendingPathComponent("task.toml").path)
        func req(_ key: String) throws -> String {
            guard let v = toml.string(key) else { throw BenchError.malformedTask(id, "missing \(key)") }
            return v
        }
        guard let lang = BenchLanguage(loose: try req("metadata.language")) else {
            throw BenchError.malformedTask(id, "unknown language \(toml.string("metadata.language") ?? "?")")
        }
        func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }
        return TaskSpec(
            id: id,
            extId: try req("metadata.ext_id"),
            displayTitle: toml.string("metadata.display_title") ?? id,
            displayDescription: toml.string("metadata.display_description") ?? "",
            originalTitle: toml.string("metadata.original_title") ?? "",
            category: BenchCategory(loose: toml.string("metadata.category") ?? "other"),
            language: lang,
            repo: repo,
            repositoryURL: try req("metadata.repository_url"),
            baseCommitHash: try req("metadata.base_commit_hash"),
            verifierTimeoutSec: toml.double("verifier.timeout_sec") ?? 1800,
            agentTimeoutSec: toml.double("agent.timeout_sec") ?? 5400,
            buildTimeoutSec: toml.double("environment.build_timeout_sec") ?? 1800,
            allowInternet: toml.bool("environment.allow_internet") ?? false,
            cpus: toml.int("environment.cpus") ?? 2,
            memoryMB: toml.int("environment.memory_mb") ?? 8192,
            storageMB: toml.int("environment.storage_mb") ?? 20480,
            prebuiltImage: toml.string("environment.docker_image") ?? "",
            taskDir: dir.path,
            instructionPath: path("instruction.md"),
            dockerfilePath: path("environment/Dockerfile"),
            testShPath: path("tests/test.sh"),
            testPatchPath: path("tests/test.patch"),
            solutionPatchPath: path("solution/solution.patch"),
            solveShPath: path("solution/solve.sh"))
    }

    public func task(_ id: String) throws -> TaskSpec {
        guard let t = byId[id] else { throw BenchError.taskNotFound(id) }
        return t
    }

    /// Filter by language/category.
    public func filtered(languages: Set<BenchLanguage>? = nil,
                         categories: Set<BenchCategory>? = nil) -> [TaskSpec] {
        tasks.filter { t in
            (languages?.contains(t.language) ?? true) &&
            (categories?.contains(t.category) ?? true)
        }
    }

    /// Deterministic random selection of `n` tasks using a seeded PRNG.
    public func randomSample(_ n: Int, seed: UInt64, from pool: [TaskSpec]? = nil) -> [TaskSpec] {
        var rng = SplitMix64(seed: seed)
        var arr = pool ?? tasks
        // Fisher–Yates partial shuffle.
        if n >= arr.count { arr.shuffle(using: &rng); return arr }
        for i in 0..<n {
            let j = Int(rng.next() % UInt64(arr.count - i)) + i
            arr.swapAt(i, j)
        }
        return Array(arr.prefix(n))
    }
}

/// A small, deterministic, seedable PRNG (SplitMix64). `codex-bench` may seed
/// freely — unlike the Workflows engine, it has no replay-determinism
/// constraint — but we still record the seed so a `--random` run reproduces.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
