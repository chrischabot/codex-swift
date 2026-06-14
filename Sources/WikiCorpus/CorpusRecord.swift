import Foundation

/// One topic wiki = one provider-stamped MemoryStore DB file. The registry maps
/// a corpus name to its DB path + the EXACT embedding-provider-id that store was
/// stamped with, so consumers open the store with that stamp instead of
/// brute-forcing candidate dimensions (which both fixes the dim-probe smell and
/// tightens a real hole — the wiki read path skips provider-id verification today).
public struct CorpusRecord: Codable, Sendable, Equatable {
    public var name: String
    /// DB path. Stored `<HUB>`-relative when under the hub root (iCloud / cross-Mac
    /// portability); resolve with `CorpusRegistry.resolvedDBPath(_:)`.
    public var dbPath: String
    /// Optional projected Obsidian vault root (also `<HUB>`-relative when under hub).
    public var vaultPath: String?
    /// MUST equal the store's `embedding_provider_id` stamp. nil only for a
    /// not-yet-stamped store (the first open stamps it).
    public var embeddingProviderID: String?
    public var embeddingDimension: Int
    public var status: CorpusStatus
    public var description: String
    public var createdAt: Int64

    public init(name: String, dbPath: String, vaultPath: String? = nil,
                embeddingProviderID: String? = nil, embeddingDimension: Int = 1536,
                status: CorpusStatus = .active, description: String = "", createdAt: Int64 = 0) {
        self.name = name; self.dbPath = dbPath; self.vaultPath = vaultPath
        self.embeddingProviderID = embeddingProviderID; self.embeddingDimension = embeddingDimension
        self.status = status; self.description = description; self.createdAt = createdAt
    }
}

public enum CorpusStatus: String, Codable, Sendable, Equatable {
    case active, archived
}

/// On-disk shape of `<hub>/corpora.json` — the only cross-topic file (the
/// `wikis.json` analog). Carries no embedding space itself, so it lives outside
/// any strict-stamped store.
struct CorpusRegistryFile: Codable {
    var version: Int = 1
    var defaultName: String = "default"
    var corpora: [CorpusRecord] = []
}

public enum CorpusError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case alreadyExists(String)
    case archived(String)
    case stampConflict(String)
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let n):       return "corpus not found: \(n)"
        case .alreadyExists(let n):  return "corpus already exists: \(n)"
        case .archived(let n):       return "corpus is archived: \(n)"
        case .stampConflict(let m):  return "corpus store stamp conflict: \(m)"
        case .io(let m):             return "corpus registry io: \(m)"
        }
    }
}
