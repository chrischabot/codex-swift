import Foundation
import MemoryStore

/// A bounded LRU of open `MemoryStore` actors keyed by absolute DB path. The
/// multi-corpus surface opens one store per topic; with an on-device MLX model
/// also resident, an unbounded set of open WAL handles is real memory pressure —
/// so the cache caps the live set and evicts least-recently-used. Eviction just
/// drops the cache's strong reference; the store's sqlite handle closes when the
/// last reference goes away (a caller mid-operation keeps its store alive).
///
/// Opening through the cache uses the corpus's recorded provider-id/dimension
/// stamp, so the open VALIDATES the stamp (mismatch → `MemoryStoreError.invalid`)
/// instead of brute-forcing candidate dimensions.
public actor WikiStoreCache {
    private let capacity: Int
    private var stores: [String: MemoryStore] = [:]
    private var lru: [String] = []   // least-recently-used at front, MRU at end

    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    /// Open or return the cached store at `path`. `MemoryStore.init` is a
    /// synchronous throwing call, so there is no suspension between the cache
    /// miss and the insert — concurrent callers for the same path can't race
    /// into two opens (actor isolation + no `await` gap).
    public func store(path: String, embeddingProviderID: String?, embeddingDimension: Int) throws -> MemoryStore {
        if let s = stores[path] { touch(path); return s }
        let cfg = MemoryStoreConfig(path: path, embeddingDimension: embeddingDimension,
                                    embeddingProviderID: embeddingProviderID)
        let s = try MemoryStore(cfg)
        stores[path] = s
        touch(path)
        evictIfNeeded()
        return s
    }

    public func store(for record: CorpusRecord, absolutePath: String) throws -> MemoryStore {
        try store(path: absolutePath, embeddingProviderID: record.embeddingProviderID,
                  embeddingDimension: record.embeddingDimension)
    }

    public func count() -> Int { stores.count }

    /// Drop every cached store (wire to `MemoryPressureMonitor` critical pressure).
    public func evictAll() { stores.removeAll(); lru.removeAll() }

    /// Keep only the `keep` most-recently-used (wire to memory-pressure warnings).
    public func trim(to keep: Int) {
        let target = max(0, keep)
        while stores.count > target, let victim = lru.first {
            lru.removeFirst()
            stores[victim] = nil
        }
    }

    private func touch(_ path: String) {
        lru.removeAll { $0 == path }
        lru.append(path)
    }

    private func evictIfNeeded() {
        while stores.count > capacity, let victim = lru.first {
            lru.removeFirst()
            stores[victim] = nil
        }
    }
}
