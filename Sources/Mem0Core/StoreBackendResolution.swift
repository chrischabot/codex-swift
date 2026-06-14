import Foundation

// Store-backend selection — the seam that lets the mem0 vector/history store be
// swapped between the default SQLite + sqlite-vec lane and the embedded-Postgres
// (pgvector) lane WITHOUT touching `Mem0Engine` (which holds `any Mem0VectorStore`
// / `any Mem0HistoryStore`). See pglite.md.
//
// IMPORTANT: this is DISTINCT from `Mem0BackendResolver` in BackendResolution.swift,
// which selects the *inference* backend (MLX-local vs OpenAI-remote vs mock). This
// one selects the *storage* backend. Keeping them separate is deliberate — they
// vary independently (e.g. local embeddings + a Postgres store, or remote
// embeddings + the SQLite store).
//
// Default is `.sqliteVec` so that with `CODEX_MEM0_STORE_BACKEND` unset, behaviour
// is byte-for-byte identical to today and Linux/CI/minimal deployments are
// completely unaffected (the Postgres lane is macOS-only and opt-in).

/// What the caller asked for via `CODEX_MEM0_STORE_BACKEND` (or the default).
public enum Mem0StoreBackendRequest: String, Sendable, Equatable {
    /// SQLite + sqlite-vec (the portable, dependency-free default).
    case sqliteVec
    /// Embedded Postgres + pgvector, run as a supervised child postmaster bound to
    /// a UNIX socket (Architecture B in pglite.md). macOS-only.
    case postgres
    /// Unmodified Postgres + pgvector inside an Apple Containerization microVM
    /// (Architecture C fallback). macOS-26-only. Reserved; not yet wired.
    case postgresContainer
    /// Pick the safe default unless a richer backend is explicitly requested.
    case auto

    /// Parse the env knob. Unset/blank → `.sqliteVec` (NOT `.auto`) so the default
    /// path is unchanged. Accepts a few friendly aliases.
    public static func parse(_ raw: String?) -> Mem0StoreBackendRequest {
        guard let raw else { return .sqliteVec }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "sqlite", "sqlitevec", "sqlite-vec", "sqlite_vec", "vec", "default":
            return .sqliteVec
        case "postgres", "postgresql", "pg", "pgvector", "embedded-pg", "embeddedpg":
            return .postgres
        case "postgres-container", "postgrescontainer", "pg-container", "container", "microvm":
            return .postgresContainer
        case "auto":
            return .auto
        default:
            return .sqliteVec
        }
    }
}

/// The concrete store backend the runtime resolved to.
public enum Mem0ResolvedStoreBackend: String, Sendable, Equatable {
    case sqliteVec
    case postgres
    case postgresContainer
}

/// Resolution policy. Falls back to `.sqliteVec` whenever the requested richer
/// backend is unavailable on this host, so a misconfigured env never hard-fails
/// the daemon — it degrades to the safe default and the caller can log the gap.
public enum Mem0StoreBackendResolver {
    /// - Parameters:
    ///   - requested: parsed `CODEX_MEM0_STORE_BACKEND`.
    ///   - postgresAvailable: whether a usable `postgres` server binary + pgvector
    ///     were found on this host (see `EmbeddedPG.PGPaths`).
    ///   - containerAvailable: whether the Apple `container` runtime is usable.
    public static func resolve(_ requested: Mem0StoreBackendRequest,
                               postgresAvailable: Bool,
                               containerAvailable: Bool = false) -> Mem0ResolvedStoreBackend {
        switch requested {
        case .sqliteVec:
            return .sqliteVec
        case .postgres:
            return postgresAvailable ? .postgres : .sqliteVec
        case .postgresContainer:
            return containerAvailable ? .postgresContainer : .sqliteVec
        case .auto:
            // `auto` prefers the safe, portable default. It only escalates to a
            // richer backend if one is available AND the default would be a
            // genuine downgrade — but since sqlite-vec is correct everywhere, we
            // keep `auto == sqliteVec` until a future heuristic (corpus size,
            // concurrency need) justifies otherwise. Documented in pglite.md.
            return .sqliteVec
        }
    }

    /// True when the resolver had to silently fall back from the request — callers
    /// should log this so a typo or a missing PG install is visible.
    public static func didFallBack(_ requested: Mem0StoreBackendRequest,
                                   _ resolved: Mem0ResolvedStoreBackend) -> Bool {
        switch (requested, resolved) {
        case (.postgres, .postgres), (.postgresContainer, .postgresContainer),
             (.sqliteVec, .sqliteVec), (.auto, .sqliteVec):
            return false
        case (.postgres, _), (.postgresContainer, _):
            return true
        default:
            return false
        }
    }
}
