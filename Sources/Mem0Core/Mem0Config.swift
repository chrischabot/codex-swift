import Foundation

/// Engine-level configuration. In the Swift port providers (embedder/LLM/vector
/// store/history store) are injected directly into `Mem0Engine`, so this holds
/// only the engine knobs (mirroring the non-provider fields of the Rust
/// `MemoryConfig`).
public struct Mem0Config: Sendable, Equatable {
    /// Path to the SQLite history database (`":memory:"` for ephemeral).
    public var historyDbPath: String
    /// API version marker.
    public var version: String
    /// Optional custom extraction instructions threaded into the additive prompt.
    public var customInstructions: String?

    /// When true, the add pipeline RECONCILES each extracted fact against existing
    /// memories instead of being ADD-only (gbrain.md Wave 0.4): a near-duplicate
    /// (cosine ≥ `dupCosineThreshold`) is skipped, and a mid-band match
    /// (≥ `reconcileCosineThreshold`) is sent through the LLM update pass which
    /// emits UPDATE / DELETE / ADD / NONE. Production enable path: env
    /// `CODEX_MEM0_RECONCILE=1` (this property-level default, mirroring
    /// `Mem0SQLiteStore.enforceTenantScope` — keeps `init` stable) or the
    /// `[memory.mem0] reconcile_on_add` TOML key (threaded via Mem0ProviderConfig).
    /// Without it mem0 is ADD-only and a contradicting fact duplicates instead of
    /// superseding (and can re-inject on recall).
    public var reconcileOnAdd: Bool = (ProcessInfo.processInfo.environment["CODEX_MEM0_RECONCILE"] == "1")
    /// Cosine ≥ this → a new fact is a near-duplicate of an existing one: skip, no LLM.
    public var dupCosineThreshold: Double = 0.95
    /// Cosine in `[reconcileCosineThreshold, dupCosineThreshold)` → LLM reconciliation.
    public var reconcileCosineThreshold: Double = 0.70

    public init(historyDbPath: String = ":memory:",
                version: String = "v1.1",
                customInstructions: String? = nil) {
        self.historyDbPath = historyDbPath
        self.version = version
        self.customInstructions = customInstructions
    }
}