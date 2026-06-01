import Foundation

public struct Mount: Sendable {
    public var host: String
    public var container: String
    public init(_ host: String, _ container: String) { self.host = host; self.container = container }
}

public enum BenchNetwork: Sendable {
    case none          // air-gapped (faithful anti-cheat; deps are pre-baked)
    case nat           // default egress (only used during image build)
}

/// Operations the runner needs from a container engine. `AppleContainerRuntime`
/// is the native macOS implementation; the protocol keeps a Docker fallback
/// possible for CI/Linux without touching callers.
public protocol ContainerRuntime: Sendable {
    var name: String { get }
    var arch: String { get }
    func ensureAvailable() async throws
    func imageExists(_ ref: String) async -> Bool
    func pull(_ ref: String, timeout: Duration) async -> ProcessResult
    func build(dockerfile: String, contextDir: String, tag: String, timeout: Duration) async -> ProcessResult
    func runOneShot(image: String, mounts: [Mount], network: BenchNetwork,
                    command: [String], timeout: Duration, cpus: Int, memoryMB: Int) async -> ProcessResult
    /// Start a detached, long-lived container (CMD overridden to idle) and
    /// return its id. Use `exec` to run commands inside it.
    func startDetached(image: String, mounts: [Mount], network: BenchNetwork,
                       name: String, cpus: Int, memoryMB: Int) async throws -> String
    func exec(_ id: String, workdir: String?, env: [String: String],
              command: [String], timeout: Duration?) async -> ProcessResult
    /// The resolved (executable, args) to run a command in the container, so a
    /// caller can spawn it directly with a streaming pipe it owns (used by the
    /// exec-server bridge for live output + real kill-on-terminate).
    func execCommand(_ id: String, workdir: String?, env: [String: String],
                     command: [String]) -> (executable: String, args: [String])
    func cpOut(_ id: String, from: String, to: String) async -> ProcessResult
    func remove(_ id: String) async
}

public struct AppleContainerRuntime: ContainerRuntime {
    public let name = "apple/container"
    public let arch: String
    private let bin: String

    public init(arch: String = "arm64", bin: String = "container") {
        self.arch = arch
        self.bin = Self.resolve(bin)
    }

    private static func resolve(_ bin: String) -> String {
        if bin.hasPrefix("/") { return bin }
        for c in ["/usr/local/bin/\(bin)", "/opt/homebrew/bin/\(bin)"] where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return bin   // fall back to PATH lookup via /usr/bin/env
    }

    private func container(_ args: [String], timeout: Duration? = nil,
                           cwd: String? = nil, stdin: String? = nil) async -> ProcessResult {
        if bin.hasPrefix("/") {
            return await Subprocess.run(bin, args, cwd: cwd, stdin: stdin, timeout: timeout)
        }
        return await Subprocess.run("/usr/bin/env", [bin] + args, cwd: cwd, stdin: stdin, timeout: timeout)
    }

    public func ensureAvailable() async throws {
        let v = await container(["--version"], timeout: .seconds(15))
        guard v.ok else { throw BenchError.runtimeUnavailable("`container` not found or not runnable: \(v.stderr)") }
        let s = await container(["system", "status"], timeout: .seconds(20))
        guard s.stdout.lowercased().contains("running") else {
            throw BenchError.runtimeUnavailable("apiserver not running — run `container system start` (\(s.stdout)\(s.stderr))")
        }
    }

    public func imageExists(_ ref: String) async -> Bool {
        let r = await container(["image", "ls"], timeout: .seconds(30))
        // `container image ls` prints NAME TAG ... ; ref may be name:tag.
        let (n, t) = Self.splitRef(ref)
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if cols.count >= 2, cols[0] == n, cols[1] == t { return true }
        }
        return false
    }

    private static func splitRef(_ ref: String) -> (String, String) {
        // Split on the LAST ':' that isn't part of a registry port — deep-swe
        // refs are "registry/path:tag" or "name:tag"; tags have no '/'.
        if let idx = ref.lastIndex(of: ":"), !ref[ref.index(after: idx)...].contains("/") {
            return (String(ref[..<idx]), String(ref[ref.index(after: idx)...]))
        }
        return (ref, "latest")
    }

    public func pull(_ ref: String, timeout: Duration) async -> ProcessResult {
        await container(["image", "pull", "--platform", "linux/\(arch)", ref], timeout: timeout)
    }

    public func build(dockerfile: String, contextDir: String, tag: String,
                      timeout: Duration) async -> ProcessResult {
        await container(["build", "--arch", arch, "-t", tag, "-f", dockerfile, contextDir], timeout: timeout)
    }

    private func mountArgs(_ mounts: [Mount]) -> [String] {
        mounts.flatMap { ["-v", "\($0.host):\($0.container)"] }
    }
    private func networkArgs(_ network: BenchNetwork) -> [String] {
        switch network { case .none: return ["--network", "none"]; case .nat: return [] }
    }

    private func resourceArgs(cpus: Int, memoryMB: Int) -> [String] {
        var a: [String] = []
        if cpus > 0 { a += ["-c", "\(cpus)"] }
        if memoryMB > 0 { a += ["-m", "\(memoryMB)M"] }
        return a
    }

    public func runOneShot(image: String, mounts: [Mount], network: BenchNetwork,
                           command: [String], timeout: Duration,
                           cpus: Int = 4, memoryMB: Int = 4096) async -> ProcessResult {
        var args = ["run", "--rm", "--arch", arch]
        args += resourceArgs(cpus: cpus, memoryMB: memoryMB)
        args += networkArgs(network)
        args += mountArgs(mounts)
        args.append(image)
        args += command
        return await container(args, timeout: timeout)
    }

    public func startDetached(image: String, mounts: [Mount], network: BenchNetwork,
                              name: String, cpus: Int = 4, memoryMB: Int = 4096) async throws -> String {
        var args = ["run", "-d", "--arch", arch, "--name", name]
        args += resourceArgs(cpus: cpus, memoryMB: memoryMB)
        args += networkArgs(network)
        args += mountArgs(mounts)
        args.append(image)
        // Idle forever so we can `exec` into it for the whole agent turn.
        args += ["sleep", "infinity"]
        let r = await container(args, timeout: .seconds(120))
        guard r.ok else { throw BenchError.process("container run -d", r.exitCode, r.stderr.isEmpty ? r.stdout : r.stderr) }
        // `run -d` prints the id (or we fall back to the name we assigned).
        let id = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? name : id
    }

    public func exec(_ id: String, workdir: String?, env: [String: String],
                     command: [String], timeout: Duration?) async -> ProcessResult {
        var args = ["exec"]
        if let workdir { args += ["-w", workdir] }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { args += ["-e", "\(k)=\(v)"] }
        args.append(id)
        args += command
        return await container(args, timeout: timeout)
    }

    public func execCommand(_ id: String, workdir: String?, env: [String: String],
                            command: [String]) -> (executable: String, args: [String]) {
        var a = ["exec"]
        if let workdir { a += ["-w", workdir] }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { a += ["-e", "\(k)=\(v)"] }
        a.append(id)
        // Hard in-guest backstop: nothing the agent runs may hang forever (a
        // deadlocked `go test` etc. self-dies at 30m even if we can't reach it).
        // The agent's own per-test timeouts + the tool deadline govern normally.
        // A whole task normally finishes in ~11 min, so no single command should
        // run anywhere near that. 6-min hard backstop kills a hung command fast.
        a += ["timeout", "--kill-after=10s", "360s"]
        a += command
        if bin.hasPrefix("/") { return (bin, a) }
        return ("/usr/bin/env", [bin] + a)
    }

    public func cpOut(_ id: String, from: String, to: String) async -> ProcessResult {
        await container(["cp", "\(id):\(from)", to], timeout: .seconds(300))
    }

    public func remove(_ id: String) async {
        _ = await container(["rm", "-f", id], timeout: .seconds(60))
    }
}
