import Foundation
import MemoryStore

/// The hub registry: maps each topic wiki to its own provider-stamped DB file.
/// Persisted atomically to `<hubRoot>/corpora.json`. Paths under the hub are
/// stored `<HUB>`-relative so a shared (iCloud) hub survives moving between Macs
/// with different `/Users/<name>/…` roots.
public actor CorpusRegistry {
    public static let hubToken = "<HUB>"
    private let hubRoot: String
    private let filePath: String
    private var file: CorpusRegistryFile

    /// `hubRoot` is the registry directory (e.g. `$CODEX_HOME/wiki`). It is
    /// created on first write. Loads the existing registry if present.
    public init(hubRoot: String) {
        self.hubRoot = Self.normalize(hubRoot)
        self.filePath = self.hubRoot + "/corpora.json"
        self.file = Self.load(filePath) ?? CorpusRegistryFile()
    }

    // MARK: resolution

    /// Resolve the corpus for an operation. `--local` → `<cwd>/.wiki/wiki.db`;
    /// `--wiki <name>` → registry lookup (auto-registering nothing); otherwise the
    /// `default` corpus, auto-registered to `MemoryStoreConfig.defaultPath()` on
    /// first use so an existing single-store install keeps working.
    public func resolve(_ name: String?, local: Bool = false, cwd: String = ".") throws -> CorpusRecord {
        if local {
            let db = Self.normalize(cwd) + "/.wiki/wiki.db"
            return CorpusRecord(name: "local", dbPath: db, embeddingDimension: 1536,
                                description: "project-local .wiki")
        }
        if let name, name != file.defaultName {
            guard let r = file.corpora.first(where: { $0.name == name }) else {
                throw CorpusError.notFound(name)
            }
            return r
        }
        // default corpus
        if let r = file.corpora.first(where: { $0.name == file.defaultName }) { return r }
        let def = CorpusRecord(name: file.defaultName,
                               dbPath: store(MemoryStoreConfig.defaultPath()),
                               embeddingDimension: 1536, description: "default Memory Wiki")
        file.corpora.append(def)
        try persist()
        return def
    }

    /// Absolute on-disk DB path for a record (expands a leading `<HUB>`).
    public func resolvedDBPath(_ r: CorpusRecord) -> String { expand(r.dbPath) }
    public func resolvedVaultPath(_ r: CorpusRecord) -> String? { r.vaultPath.map(expand) }

    // MARK: mutation

    @discardableResult
    public func register(_ r: CorpusRecord) throws -> CorpusRecord {
        if file.corpora.contains(where: { $0.name == r.name }) {
            throw CorpusError.alreadyExists(r.name)
        }
        var rec = r
        rec.dbPath = store(expand(r.dbPath))           // normalize to <HUB>-relative when under hub
        if let v = r.vaultPath { rec.vaultPath = store(expand(v)) }
        file.corpora.append(rec)
        try persist()
        return rec
    }

    public func archive(_ name: String, reason: String? = nil) throws {
        guard let i = file.corpora.firstIndex(where: { $0.name == name }) else {
            throw CorpusError.notFound(name)
        }
        file.corpora[i].status = .archived
        if let reason, !reason.isEmpty { file.corpora[i].description += " [archived: \(reason)]" }
        try persist()
    }

    public func restore(_ name: String) throws {
        guard let i = file.corpora.firstIndex(where: { $0.name == name }) else {
            throw CorpusError.notFound(name)
        }
        file.corpora[i].status = .active
        try persist()
    }

    /// Record the provider-id/dim a store was actually stamped with (called after
    /// the first open stamps a freshly-created corpus store).
    public func setStamp(_ name: String, providerID: String?, dimension: Int) throws {
        guard let i = file.corpora.firstIndex(where: { $0.name == name }) else {
            throw CorpusError.notFound(name)
        }
        file.corpora[i].embeddingProviderID = providerID
        file.corpora[i].embeddingDimension = dimension
        try persist()
    }

    // MARK: query

    public func list(includeArchived: Bool = false) -> [CorpusRecord] {
        includeArchived ? file.corpora : file.corpora.filter { $0.status == .active }
    }

    public func get(_ name: String) -> CorpusRecord? {
        file.corpora.first(where: { $0.name == name })
    }

    public var defaultName: String { file.defaultName }

    // MARK: - path portability

    /// Convert an absolute path under the hub to a `<HUB>`-relative token form;
    /// leave paths outside the hub absolute.
    private func store(_ absolute: String) -> String {
        let abs = Self.normalize(absolute)
        if abs == hubRoot { return Self.hubToken }
        if abs.hasPrefix(hubRoot + "/") {
            return Self.hubToken + String(abs.dropFirst(hubRoot.count))
        }
        return abs
    }

    /// Expand a possibly-`<HUB>`-relative stored path back to absolute.
    private func expand(_ stored: String) -> String {
        if stored == Self.hubToken { return hubRoot }
        if stored.hasPrefix(Self.hubToken) {
            return hubRoot + String(stored.dropFirst(Self.hubToken.count))
        }
        return stored
    }

    // MARK: - persistence (atomic .tmp -> rename)

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(atPath: hubRoot, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            // withoutEscapingSlashes keeps the shared (iCloud) corpora.json
            // human-readable: paths stay `<HUB>/topics/...`, not `<HUB>\/topics\/...`.
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try enc.encode(file)
            let tmp = filePath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            // rename is atomic on POSIX; replace any existing file
            if FileManager.default.fileExists(atPath: filePath) {
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: filePath),
                                                          withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try FileManager.default.moveItem(atPath: tmp, toPath: filePath)
            }
        } catch {
            throw CorpusError.io(String(describing: error))
        }
    }

    private static func load(_ path: String) -> CorpusRegistryFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(CorpusRegistryFile.self, from: data)
    }

    /// Trim a trailing slash so `hasPrefix(hubRoot + "/")` is well-defined.
    private static func normalize(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
