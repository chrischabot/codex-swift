import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Manages the lifecycle of a locally-spawned native PostgreSQL postmaster:
/// `initdb` once, start it bound ONLY to a UNIX socket, wait for readiness, make
/// sure the target database exists, and stop it gracefully. Reusable by anything
/// in the project that wants an embedded Postgres (pglite.md, Architecture B).
///
/// Security invariant (enforced at spawn): the postmaster is started with
/// `-c listen_addresses=''`, so NO TCP listener is ever opened. The cluster is
/// `initdb`'d with `--auth-local=trust --auth-host=reject`, so even a
/// mis-started TCP listener would refuse host connections. `start()` verifies the
/// invariant via `pg_isready` against the socket only.
public actor PostgresLifecycle {
    public let paths: PGPaths
    /// Extra `-c key=value` server settings appended to the spawn (e.g. tuning).
    private let extraServerSettings: [String]
    private var didProvisionDatabase = false

    public init(paths: PGPaths, extraServerSettings: [String] = []) {
        self.paths = paths
        self.extraServerSettings = extraServerSettings
    }

    public enum LifecycleError: Error, CustomStringConvertible, Sendable {
        case binaryMissing(String)
        case initdbFailed(String)
        case startFailed(String)
        case notReady(String)
        case provisioningFailed(String)
        public var description: String {
            switch self {
            case .binaryMissing(let s): return "embedded-pg: required binary missing: \(s)"
            case .initdbFailed(let s): return "embedded-pg: initdb failed: \(s)"
            case .startFailed(let s): return "embedded-pg: postmaster start failed: \(s)"
            case .notReady(let s): return "embedded-pg: postmaster not ready: \(s)"
            case .provisioningFailed(let s): return "embedded-pg: provisioning failed: \(s)"
            }
        }
    }

    /// Idempotently bring the cluster up and ensure the database exists. Safe to
    /// call repeatedly (reuses an already-running postmaster).
    public func ensureStarted() async throws {
        guard FileManager.default.isExecutableFile(atPath: paths.postgresExecutable) else {
            throw LifecycleError.binaryMissing(paths.postgresExecutable)
        }
        if !(try await isRunning()) {
            try await initializeIfNeeded()
            cleanStaleState()
            try await startPostmaster()
        }
        try await waitUntilReady(timeout: 30)
        try await assertSocketOnly()
        if !didProvisionDatabase {
            try await ensureDatabaseExists()
            didProvisionDatabase = true
        }
    }

    /// Defence before (re)start: truncate `postgresql.auto.conf` so a persisted
    /// setting (e.g. a stray `listen_addresses` override) can never survive — we
    /// own every setting via `-o`, so a clean slate is correct — and drop a stale
    /// `postmaster.pid` whose process is dead (left by a crash) so `pg_ctl start`
    /// neither refuses nor mis-detects a running cluster.
    private func cleanStaleState() {
        let autoConf = paths.dataDir + "/postgresql.auto.conf"
        if FileManager.default.fileExists(atPath: autoConf) {
            try? "# managed by EmbeddedPG — settings are passed via pg_ctl -o\n"
                .write(toFile: autoConf, atomically: true, encoding: .utf8)
        }
        let pidFile = paths.dataDir + "/postmaster.pid"
        if let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let firstLine = s.split(separator: "\n").first,
           let pid = Int32(firstLine.trimmingCharacters(in: .whitespaces)) {
            #if canImport(Darwin)
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(atPath: pidFile)
            }
            #endif
        }
    }

    /// Enforce (not just assume) the no-TCP invariant: the postmaster must report
    /// `listen_addresses=''`. Best-effort — skipped if `psql` is unavailable.
    private func assertSocketOnly() async throws {
        let psql = Self.siblingTool(paths, "psql")
        guard FileManager.default.isExecutableFile(atPath: psql) else { return }
        let r = try await run(psql, [
            "-h", paths.socketDir, "-p", "\(paths.port)", "-U", paths.username,
            "-d", "postgres", "-tAc", "SHOW listen_addresses",
        ])
        let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.exitCode == 0 && !value.isEmpty {
            throw LifecycleError.notReady("listen_addresses must be '' (socket-only) but is '\(value)' — refusing to serve")
        }
    }

    /// Gracefully stop the postmaster (`pg_ctl stop -m fast`). Best-effort.
    public func stop() async throws {
        guard FileManager.default.isExecutableFile(atPath: paths.pgCtlExecutable) else { return }
        _ = try? await run(paths.pgCtlExecutable, ["stop", "-D", paths.dataDir, "-m", "fast", "-w", "-t", "30"])
    }

    /// `pg_ctl status` → running?  (exit 0 = running, 3 = not running, 4 = bad dir)
    public func isRunning() async throws -> Bool {
        guard paths.isInitialized,
              FileManager.default.isExecutableFile(atPath: paths.pgCtlExecutable) else { return false }
        let r = try await run(paths.pgCtlExecutable, ["status", "-D", paths.dataDir])
        return r.exitCode == 0
    }

    // MARK: - steps

    private func initializeIfNeeded() async throws {
        if paths.isInitialized { return }
        try FileManager.default.createDirectory(atPath: paths.dataDir, withIntermediateDirectories: true)
        // `--auth-local=trust` (socket peers trusted) + `--auth-host=reject`
        // (defence-in-depth: no TCP host auth even if a listener slipped in).
        let r = try await run(paths.initdbExecutable, [
            "-D", paths.dataDir,
            "-U", paths.username,
            "--auth-local=trust",
            "--auth-host=reject",
            "--no-instructions",
            "-E", "UTF8",
        ])
        if r.exitCode != 0 {
            throw LifecycleError.initdbFailed(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
    }

    private func startPostmaster() async throws {
        try FileManager.default.createDirectory(
            atPath: paths.socketDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // All settings passed via `-o` so they cannot be overridden by a stray
        // postgresql.auto.conf. listen_addresses='' ⇒ socket-only.
        var settings = [
            "-c", "listen_addresses=''",
            "-k", paths.socketDir,
            "-c", "unix_socket_permissions=0700",
            "-c", "port=\(paths.port)",
        ]
        for s in extraServerSettings { settings.append(contentsOf: ["-c", s]) }
        let optionString = settings.joined(separator: " ")
        let logFile = (paths.dataDir as NSString).deletingLastPathComponent + "/postmaster.log"
        let r = try await run(paths.pgCtlExecutable, [
            "start", "-D", paths.dataDir, "-w", "-t", "30",
            "-l", logFile, "-o", optionString,
        ])
        if r.exitCode != 0 {
            let tail = (try? String(contentsOfFile: logFile, encoding: .utf8))?.suffix(800) ?? ""
            throw LifecycleError.startFailed((r.stderr.isEmpty ? r.stdout : r.stderr) + "\n--- postmaster.log ---\n" + tail)
        }
    }

    private func waitUntilReady(timeout: Int) async throws {
        let isready = paths.pgIsReadyExecutable
        for _ in 0..<(timeout * 5) {
            let r = try await run(isready, ["-h", paths.socketDir, "-p", "\(paths.port)", "-q"])
            if r.exitCode == 0 { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw LifecycleError.notReady("pg_isready did not succeed on \(paths.unixSocketPath) within \(timeout)s")
    }

    /// Ensure the target database exists (create via `createdb` if missing).
    /// The schema/extension/roles are owned by the store layer, not here.
    private func ensureDatabaseExists() async throws {
        let createdb = Self.siblingTool(paths, "createdb")
        let psql = Self.siblingTool(paths, "psql")
        // Check existence first (avoids a spurious error log on every start).
        if FileManager.default.isExecutableFile(atPath: psql) {
            let check = try await run(psql, [
                "-h", paths.socketDir, "-p", "\(paths.port)", "-U", paths.username,
                "-d", "postgres", "-tAc",
                "SELECT 1 FROM pg_database WHERE datname='\(paths.database)'",
            ])
            if check.exitCode == 0 && check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
        }
        guard FileManager.default.isExecutableFile(atPath: createdb) else {
            throw LifecycleError.provisioningFailed("createdb not found near \(paths.serverBinDir)")
        }
        let r = try await run(createdb, [
            "-h", paths.socketDir, "-p", "\(paths.port)", "-U", paths.username, paths.database,
        ])
        // Tolerate the race where the database already exists.
        if r.exitCode != 0 && !r.stderr.contains("already exists") {
            throw LifecycleError.provisioningFailed(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
    }

    private static func siblingTool(_ paths: PGPaths, _ tool: String) -> String {
        let inKeg = paths.serverBinDir + "/" + tool
        if FileManager.default.isExecutableFile(atPath: inKeg) { return inKeg }
        for c in ["/opt/homebrew/opt/libpq/bin/\(tool)", "/usr/local/opt/libpq/bin/\(tool)", "/usr/bin/\(tool)"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return inKeg
    }

    // MARK: - async process runner

    struct ProcResult: Sendable { let exitCode: Int32; let stdout: String; let stderr: String }

    /// Run a child process off the cooperative pool (on a detached thread) so the
    /// blocking pipe reads never stall an actor's executor. Server logs go to the
    /// `-l` logfile, so the captured pipes stay small (no 64 KB deadlock risk).
    private func run(_ launchPath: String, _ args: [String]) async throws -> ProcResult {
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return ProcResult(exitCode: p.terminationStatus,
                              stdout: String(decoding: o, as: UTF8.self),
                              stderr: String(decoding: e, as: UTF8.self))
        }.value
    }
}
