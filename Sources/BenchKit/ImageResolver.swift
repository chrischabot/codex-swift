import Foundation

/// Resolves a runnable, native-arch image for a task and extracts a reusable
/// `/app` template (source + installed deps) the per-run workspace clones from.
///
/// Strategy (chosen): **build arm64 from the task Dockerfile** (the shared
/// `mars-base` has a native arm64 variant and installs are arch-agnostic), with
/// the base cached once to avoid `public.ecr.aws` rate-limits.
public struct ImageResolver: Sendable {
    public let runtime: any ContainerRuntime
    public let paths: BenchPaths
    public typealias Log = @Sendable (String) -> Void

    public init(runtime: any ContainerRuntime, paths: BenchPaths) {
        self.runtime = runtime
        self.paths = paths
    }

    public func localTag(_ task: TaskSpec) -> String {
        "codex-bench/\(task.extId):\(runtime.arch)"
    }

    /// The base image referenced by the task's Dockerfile `FROM` line
    /// (normally `public.ecr.aws/x8v8d7g8/mars-base:latest`).
    public func baseRef(_ task: TaskSpec) -> String {
        if let text = try? String(contentsOfFile: task.dockerfilePath, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.uppercased().hasPrefix("FROM ") {
                    return t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return "public.ecr.aws/x8v8d7g8/mars-base:latest"
    }

    /// Pull the base image once (cached), retrying on ECR 429 with backoff.
    public func ensureBase(_ ref: String, log: Log) async throws {
        if await runtime.imageExists(ref) { return }
        log("pulling base \(ref) (\(runtime.arch))…")
        var delay: UInt64 = 30
        for attempt in 1...8 {
            let r = await runtime.pull(ref, timeout: .seconds(1200))
            if r.ok { return }
            if await runtime.imageExists(ref) { return }
            let blob = (r.stdout + r.stderr).lowercased()
            if blob.contains("429") || blob.contains("toomanyrequests") || blob.contains("rate exceeded") {
                log("  base pull rate-limited (attempt \(attempt)); backing off \(delay)s")
                try? await Task.sleep(for: .seconds(Double(delay)))
                delay = min(delay * 2, 240)
                continue
            }
            if attempt == 8 {
                throw BenchError.process("container image pull \(ref)", r.exitCode,
                                         String((r.stderr.isEmpty ? r.stdout : r.stderr).suffix(400)))
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Some task Dockerfiles hard-code x86_64 binary downloads (assuming a
    /// Docker/amd64 build host). On our native-arm64 builds those binaries trap
    /// at build time (e.g. cliffy fetches `deno-x86_64-unknown-linux-gnu` →
    /// `deno cache` exits 133). When building arm64, rewrite the well-known
    /// arch-tagged download URLs to their aarch64 variants and build from a
    /// patched copy of the Dockerfile (written into the build context dir so the
    /// context is unchanged). Returns the path to build from (original if no
    /// rewrite was needed). Idempotent.
    private func archPatchedDockerfile(_ task: TaskSpec, contextDir: String, log: Log) -> String {
        guard runtime.arch == "arm64",
              let text = try? String(contentsOfFile: task.dockerfilePath, encoding: .utf8)
        else { return task.dockerfilePath }
        var patched = text
        // Binary-release naming conventions seen in the suite. Add patterns here
        // as new x86-only downloads surface.
        let subs = [
            ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"),   // deno, rust-style
            ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"),
            ("linux-x86_64", "linux-aarch64"),                            // many gh-release assets
            ("linux-amd64", "linux-arm64"),                               // go-style
        ]
        for (from, to) in subs { patched = patched.replacingOccurrences(of: from, with: to) }
        guard patched != text else { return task.dockerfilePath }
        let out = (contextDir as NSString).appendingPathComponent(".Dockerfile.arm64")
        do {
            try patched.write(toFile: out, atomically: true, encoding: .utf8)
            log("patched x86_64→aarch64 binary downloads for arm64 build (\(task.id))")
            return out
        } catch { return task.dockerfilePath }
    }

    /// Ensure a native-arch image exists for the task; returns its local tag.
    public func ensureImage(_ task: TaskSpec, log: Log) async throws -> String {
        let tag = localTag(task)
        if await runtime.imageExists(tag) { log("image cached: \(tag)"); return tag }
        try await ensureBase(baseRef(task), log: log)
        log("building \(tag) from Dockerfile…")
        let contextDir = (task.dockerfilePath as NSString).deletingLastPathComponent
        let dockerfile = archPatchedDockerfile(task, contextDir: contextDir, log: log)
        // Retry: image builds clone repos + fetch deps (deno/npm/pip), which fail
        // transiently (network, registry hiccups — e.g. cliffy's `deno cache`).
        var lastErr = ""
        for attempt in 1...3 {
            let r = await runtime.build(dockerfile: dockerfile, contextDir: contextDir,
                                        tag: tag, timeout: .seconds(task.buildTimeoutSec))
            let exists = await runtime.imageExists(tag)
            if r.ok || exists { log("built \(tag)"); return tag }
            lastErr = String((r.stderr.isEmpty ? r.stdout : r.stderr).suffix(600))
            log("build attempt \(attempt)/3 failed; retrying…")
            try? await Task.sleep(for: .seconds(8))
        }
        throw BenchError.process("container build \(tag)", 1, lastErr)
    }

    /// Extract `/app` (source + installed deps) from the image into a cached
    /// template dir the runner clones per run. Idempotent.
    public func ensureTemplate(_ task: TaskSpec, image: String, log: Log) async throws -> URL {
        let dir = paths.templateDir(task.extId, arch: runtime.arch)
        let marker = dir.appendingPathComponent(".git")   // /app is a git repo at base commit
        if FileManager.default.fileExists(atPath: marker.path) { return dir }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("extracting /app template for \(task.id)…")
        // `container cp` is a plugin that may be absent (0.12.3); instead copy
        // /app into a bind-mounted host dir from inside the container (Linux
        // `cp -a`, preserving perms/links). Bind-mount writeback is proven.
        let r = await runtime.runOneShot(
            image: image, mounts: [Mount(dir.path, "/out")], network: .none,
            command: ["bash", "-lc", "cp -a /app/. /out/ && echo EXTRACT_OK"],
            timeout: .seconds(900), cpus: 4, memoryMB: 4096)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw BenchError.process("extract /app", r.exitCode,
                                     "cp failed or /app missing .git: \(String((r.stderr + r.stdout).suffix(400)))")
        }
        log("template ready: \(dir.path)")
        return dir
    }
}
