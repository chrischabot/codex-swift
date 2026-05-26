import Foundation

/// Per-session LRU cache for query embeddings, keyed by `(modelId,
/// normalizationVersion, query)`. The MemoryRetriever's `vecTopHits` runs
/// the same query repeatedly (auto-recall, hybrid pre-rerank, snippet
/// rebuild, etc.); embeds are the single most expensive step in the
/// retrieval pipeline (10-100ms on a remote provider). Caching them per
/// session reclaims that cost on the very next hit.
///
/// **Eviction:** classic doubly-linked-list LRU. O(1) put / get / evict.
///
/// **Thread-safety:** all public operations take an `NSLock`. The class is
/// `@unchecked Sendable` because the lock fully serialises access to the
/// mutable state.
///
/// **Key shape:** model id and normalization version are baked into the
/// composite key so a cross-model or cross-tokenizer cache hit is
/// impossible by construction. Bumping `normalizationVersion` after
/// upstream changes to query preprocessing is enough to invalidate the
/// whole cache without dropping unrelated entries.
public final class QueryEmbeddingCache: @unchecked Sendable {

    public let capacity: Int
    public let modelId: String
    public let normalizationVersion: Int

    private final class Node {
        let key: String
        var value: [Float]
        var prev: Node?
        var next: Node?
        init(key: String, value: [Float]) { self.key = key; self.value = value }
    }

    private let lock = NSLock()
    private var map: [String: Node] = [:]
    private var head: Node?   // MRU
    private var tail: Node?   // LRU

    private var _hitCount: Int = 0
    private var _missCount: Int = 0

    public init(capacity: Int, modelId: String, normalizationVersion: Int = 1) {
        precondition(capacity > 0, "QueryEmbeddingCache capacity must be > 0")
        self.capacity = capacity
        self.modelId = modelId
        self.normalizationVersion = normalizationVersion
    }

    // MARK: - public API

    public var size: Int { lock.lock(); defer { lock.unlock() }; return map.count }
    public var hitCount: Int { lock.lock(); defer { lock.unlock() }; return _hitCount }
    public var missCount: Int { lock.lock(); defer { lock.unlock() }; return _missCount }

    public func get(_ query: String) -> [Float]? {
        let key = composite(query)
        lock.lock(); defer { lock.unlock() }
        guard let node = map[key] else {
            _missCount += 1
            return nil
        }
        promote(node)
        _hitCount += 1
        return node.value
    }

    public func put(_ query: String, _ value: [Float]) {
        let key = composite(query)
        lock.lock(); defer { lock.unlock() }
        if let existing = map[key] {
            existing.value = value
            promote(existing)
            return
        }
        let node = Node(key: key, value: value)
        map[key] = node
        prepend(node)
        if map.count > capacity, let evicted = tail {
            remove(evicted)
            map.removeValue(forKey: evicted.key)
        }
    }

    public func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
    }

    /// Reset the hit/miss counters without dropping the warm cache. Used by
    /// tests that pre-load entries and then want to measure steady-state
    /// hit rate.
    public func resetForTests() {
        lock.lock(); defer { lock.unlock() }
        _hitCount = 0
        _missCount = 0
    }

    // MARK: - internals

    @inline(__always)
    private func composite(_ query: String) -> String {
        "\(modelId)\u{1F}\(normalizationVersion)\u{1F}\(query)"
    }

    private func prepend(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func remove(_ node: Node) {
        let p = node.prev, n = node.next
        p?.next = n
        n?.prev = p
        if head === node { head = n }
        if tail === node { tail = p }
        node.prev = nil
        node.next = nil
    }

    private func promote(_ node: Node) {
        if head === node { return }
        remove(node)
        prepend(node)
    }
}
