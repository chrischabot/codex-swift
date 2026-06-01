import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Cache + run-output directory layout for the benchmark runner.
public struct BenchPaths: Sendable {
    public let cacheRoot: URL          // images templates etc.
    public let resultsRoot: URL        // per-run outputs

    public init(env: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let c = env["CODEX_BENCH_CACHE"], !c.isEmpty {
            cacheRoot = URL(fileURLWithPath: c)
        } else {
            cacheRoot = home.appendingPathComponent("Library/Caches/codex-bench")
        }
        if let r = env["CODEX_BENCH_RESULTS"], !r.isEmpty {
            resultsRoot = URL(fileURLWithPath: r)
        } else {
            resultsRoot = home.appendingPathComponent(".codex-bench/results")
        }
    }

    public func templateDir(_ extId: String, arch: String) -> URL {
        cacheRoot.appendingPathComponent("templates/\(arch)/\(extId)", isDirectory: true)
    }
    public func runDir(_ runId: String) -> URL {
        resultsRoot.appendingPathComponent(runId, isDirectory: true)
    }
    public func ensureDirs() {
        for d in [cacheRoot, resultsRoot,
                  cacheRoot.appendingPathComponent("templates")] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

public enum Workspace {
    /// Copy-on-write clone `src` → `dst` using APFS `clonefile` (via
    /// `copyfile(COPYFILE_CLONE)`), falling back to a normal recursive copy off
    /// APFS. Near-instant even for large `node_modules`/`.venv` trees. We never
    /// shell out to bare `cp` (Homebrew's GNU `cp` shadows BSD `cp` and lacks
    /// `-c`).
    public static func clone(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Darwin)
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)
        let rc = src.path.withCString { s in
            dst.path.withCString { d in copyfile(s, d, nil, flags) }
        }
        if rc == 0 { return }
        // Fall through to Foundation copy (also COW on APFS).
        #endif
        try fm.copyItem(at: src, to: dst)
    }
}
