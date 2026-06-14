import Foundation

/// Filesystem + binary locations for a locally-managed PostgreSQL cluster.
///
/// Resolution order for the server binary directory (the one that holds
/// `postgres`, `initdb`, `pg_ctl`):
///   1. `CODEX_MEM0_PG_BINDIR` (explicit override — used for a bundled relocatable
///      build in pglite.md Phase 2),
///   2. Homebrew Cellar (`/opt/homebrew/Cellar/postgresql@NN/*/bin`, newest major
///      first), then the libpq keg for the client tools,
///   3. `PATH` (`postgres` on PATH).
///
/// NOTE: on macOS the Homebrew `libpq` keg ships the *client* tools
/// (`initdb`/`pg_ctl`/`psql`/`pg_isready`) on PATH but NOT the `postgres` server,
/// which lives only under the `postgresql@NN` keg — so we resolve the server keg
/// explicitly rather than trusting PATH.
public struct PGPaths: Sendable, Equatable {
    /// Directory holding the `postgres`/`initdb`/`pg_ctl` executables.
    public let serverBinDir: String
    /// The data directory (`PGDATA`).
    public let dataDir: String
    /// The UNIX-socket directory passed to `-k`. Kept SHALLOW so the resulting
    /// `<socketDir>/.s.PGSQL.<port>` path stays under the 104-byte `sun_path`
    /// limit even under a sandboxed `.app` container.
    public let socketDir: String
    /// The TCP-style port number — used ONLY as the socket-file suffix
    /// (`.s.PGSQL.<port>`); no TCP listener is ever opened (`listen_addresses=''`).
    public let port: Int
    /// Bootstrap superuser created by `initdb -U`.
    public let username: String
    /// Default database to connect to.
    public let database: String

    public init(serverBinDir: String, dataDir: String, socketDir: String,
                port: Int = 5432, username: String = "codex", database: String = "codexmem0") {
        self.serverBinDir = serverBinDir
        self.dataDir = dataDir
        self.socketDir = socketDir
        self.port = port
        // `database`/`username` are interpolated into provisioning SQL (datname=…,
        // GRANT … TO …), so constrain them to safe SQL identifiers; a value with
        // anything outside [A-Za-z0-9_] (or not starting with a letter/_) falls
        // back to the default rather than risking interpolation.
        self.username = Self.safeIdentifier(username, fallback: "codex")
        self.database = Self.safeIdentifier(database, fallback: "codexmem0")
    }

    /// Keep only inputs that are valid unquoted SQL identifiers; else `fallback`.
    static func safeIdentifier(_ s: String, fallback: String) -> String {
        let valid = !s.isEmpty
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            && (s.first.map { $0.isLetter || $0 == "_" } ?? false)
        return valid ? s : fallback
    }

    // MARK: - Executables

    public var postgresExecutable: String { serverBinDir + "/postgres" }
    public var initdbExecutable: String { serverBinDir + "/initdb" }
    public var pgCtlExecutable: String { serverBinDir + "/pg_ctl" }
    /// `pg_isready` may live in the server keg or the libpq client keg — resolve
    /// lazily, preferring the server keg.
    public var pgIsReadyExecutable: String {
        let candidate = serverBinDir + "/pg_isready"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        return Self.firstExecutable(["/opt/homebrew/opt/libpq/bin/pg_isready",
                                     "/usr/local/opt/libpq/bin/pg_isready",
                                     "/usr/bin/pg_isready"]) ?? candidate
    }

    /// The full socket file path PostgresNIO connects to.
    public var unixSocketPath: String { "\(socketDir)/.s.PGSQL.\(port)" }

    /// True once `initdb` has populated the data dir.
    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: dataDir + "/PG_VERSION")
    }

    // MARK: - Discovery

    /// Resolve a default layout under `$CODEX_HOME/mem0` (matching the SQLite
    /// store's default location). Returns nil if no server binary can be found.
    public static func resolveDefault(env: [String: String] = ProcessInfo.processInfo.environment,
                                      username: String = "codex",
                                      database: String = "codexmem0") -> PGPaths? {
        guard let bin = discoverServerBinDir(env: env) else { return nil }
        let home = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        let root = env["CODEX_MEM0_PG_ROOT"] ?? (home + "/mem0/pg")
        let dataDir = env["CODEX_MEM0_PG_DATA"] ?? (root + "/pgdata")
        // Keep the socket dir SHALLOW. A deep `$CODEX_HOME` could blow the 104-byte
        // sun_path limit, so fall back to a short `$TMPDIR`-based dir if needed.
        let preferred = env["CODEX_MEM0_PG_SOCKET_DIR"] ?? (root + "/run")
        let socketDir = Self.socketDirWithinLimit(preferred, port: 5432)
        return PGPaths(serverBinDir: bin, dataDir: dataDir, socketDir: socketDir,
                       username: username, database: database)
    }

    /// Find a directory containing the `postgres` server binary.
    public static func discoverServerBinDir(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = env["CODEX_MEM0_PG_BINDIR"],
           FileManager.default.isExecutableFile(atPath: override + "/postgres") {
            return override
        }
        // Homebrew Cellar, newest major first.
        let fm = FileManager.default
        for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            guard let kegs = try? fm.contentsOfDirectory(atPath: cellar) else { continue }
            let pgKegs = kegs.filter { $0.hasPrefix("postgresql@") }
                .sorted { majorVersion($0) > majorVersion($1) }
            for keg in pgKegs {
                let kegDir = "\(cellar)/\(keg)"
                guard let versions = try? fm.contentsOfDirectory(atPath: kegDir) else { continue }
                for v in versions.sorted(by: >) {
                    let bin = "\(kegDir)/\(v)/bin"
                    if fm.isExecutableFile(atPath: bin + "/postgres") { return bin }
                }
            }
        }
        // Bare `postgres` on PATH.
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") {
                let bin = String(dir)
                if fm.isExecutableFile(atPath: bin + "/postgres") { return bin }
            }
        }
        return nil
    }

    /// Whether the pgvector extension is installed for the resolved server build
    /// (the `vector.control` file in the server's `sharedir/extension`).
    public func pgvectorAvailable() -> Bool {
        // Derive the sharedir from the keg root (…/NN.N/bin → …/share/postgresql@NN).
        // Homebrew installs the extension under a sibling `share` keg, so probe
        // both the in-keg sharedir and the Homebrew share layout.
        let candidates = Self.shareDirsForBin(serverBinDir)
        for share in candidates {
            if FileManager.default.fileExists(atPath: share + "/extension/vector.control") {
                return true
            }
        }
        return false
    }

    /// True if a usable server binary + pgvector are present — the signal
    /// `Mem0StoreBackendResolver` uses for `postgresAvailable`.
    public static func isAvailable(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let paths = resolveDefault(env: env) else { return false }
        return FileManager.default.isExecutableFile(atPath: paths.postgresExecutable)
            && paths.pgvectorAvailable()
    }

    // MARK: - helpers

    private static func majorVersion(_ keg: String) -> Int {
        // "postgresql@18" → 18 ; "postgresql" → 0
        guard let at = keg.firstIndex(of: "@") else { return 0 }
        return Int(keg[keg.index(after: at)...]) ?? 0
    }

    private static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func shareDirsForBin(_ bin: String) -> [String] {
        var out: [String] = []
        // …/Cellar/postgresql@18/18.4/bin → …/Cellar/postgresql@18/18.4/share
        let kegShare = (bin as NSString).deletingLastPathComponent + "/share"
        out.append(kegShare)
        out.append(kegShare + "/postgresql")
        // Homebrew opt share: /opt/homebrew/share/postgresql@NN
        if let at = bin.range(of: "Cellar/postgresql@") {
            let after = bin[at.upperBound...]
            if let slash = after.firstIndex(of: "/") {
                let major = String(after[..<slash])
                let prefix = String(bin[..<at.lowerBound])  // …/opt/homebrew/
                out.append(prefix + "share/postgresql@" + major)
            }
        }
        return out
    }

    /// Ensure `<dir>/.s.PGSQL.<port>` fits in 104 bytes; otherwise fall back to a
    /// short `$TMPDIR`/`/tmp` directory keyed by a hash of the requested path so
    /// it is stable per-cluster.
    private static func socketDirWithinLimit(_ dir: String, port: Int) -> String {
        let socketFile = "\(dir)/.s.PGSQL.\(port)"
        if socketFile.utf8.count <= 103 { return dir }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        // DETERMINISTIC hash (FNV-1a) — `String.hashValue` is seeded per process,
        // so it would map the same over-long path to DIFFERENT fallback dirs across
        // runs and spawn duplicate postmasters. FNV-1a is stable across processes.
        var h: UInt64 = 1469598103934665603
        for b in dir.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let key = String(h, radix: 36)
        return "\(tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp)/codexmem0-\(key)"
    }
}
