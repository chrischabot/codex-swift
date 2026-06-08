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

    public init(historyDbPath: String = ":memory:",
                version: String = "v1.1",
                customInstructions: String? = nil) {
        self.historyDbPath = historyDbPath
        self.version = version
        self.customInstructions = customInstructions
    }
}