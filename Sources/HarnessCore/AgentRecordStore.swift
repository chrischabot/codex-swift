// P5c (multi-agent v2): persisted, encrypted-at-rest agent metadata.
//
// Upstream's multi-agent v2 persists sub-agent runtime metadata (#25721) and
// encrypts persisted payloads (#26210) inside a hosted thread-manager. The Swift
// port's `AgentRegistry` is otherwise purely in-memory (records are lost on a
// daemon restart). This seam adds an OPTIONAL write-through store so sub-agent
// records survive a restart and their potentially-sensitive `result`/`error`
// payloads are sealed at rest.
//
// The seam lives in HarnessCore (which cannot depend on `Auth`, to avoid a module
// cycle), so encryption uses CryptoKit `AES.GCM` directly with an injected
// 256-bit key — the same primitive `Auth.LocalSecretsBackend` uses, and the key
// can be sourced from the same Keychain-held material when wired from a layer
// that has `Auth` (e.g. Supervisor). macOS-native, mirroring `LocalSecrets`.
//
// The residency LRU (#26632), reload-on-delivery (#26623), and
// concurrency-by-active-execution (#26969) optimizations are deliberate
// divergences — see docs/notes/catchup-p5-divergences.md. They bound memory for a
// hosted, multi-tenant thread-manager with many concurrent agents; the
// single-operator port spawns a bounded handful, so the in-memory map is
// acceptable. Persistence here is the foundational piece those would build on.

import Foundation

/// Write-through persistence for `AgentRecord`s. All methods are async so the
/// concrete store can be its own actor; `AgentRegistry` awaits them.
public protocol AgentRecordStore: Sendable {
    /// Upsert one record.
    func put(_ record: AgentRecord) async
    /// Remove a record by its agent path.
    func remove(_ path: AgentPath) async
    /// Load all persisted records (used by `AgentRegistry.hydrate()` on startup).
    func all() async -> [AgentRecord]
}

#if canImport(CryptoKit)
import CryptoKit

/// File-backed `AgentRecordStore` that seals each record's `result`/`error`
/// payload with AES-GCM before writing. Status/path/parent/timestamps stay in
/// cleartext (they are routing metadata, not secrets); only the model-authored
/// free-text payloads are encrypted. Writes are atomic (temp-file + rename) and
/// serialized by the actor.
public actor EncryptedFileAgentRecordStore: AgentRecordStore {
    private let url: URL
    private let key: SymmetricKey
    /// In-memory mirror so `all()`/`put()` don't re-read+decrypt the whole file
    /// on every mutation. Seeded from disk on first access.
    private var cache: [String: AgentRecord]?

    public init(path: String, key: SymmetricKey) {
        self.url = URL(fileURLWithPath: path)
        self.key = key
    }

    public func put(_ record: AgentRecord) async {
        var c = loaded()
        c[record.path.raw] = record
        cache = c
        persist(c)
    }

    public func remove(_ path: AgentPath) async {
        var c = loaded()
        guard c.removeValue(forKey: path.raw) != nil else { return }
        cache = c
        persist(c)
    }

    public func all() async -> [AgentRecord] {
        Array(loaded().values).sorted { $0.path.raw < $1.path.raw }
    }

    // MARK: - Disk

    /// On-disk shape: routing metadata in clear, `result`/`error` sealed.
    private struct Wire: Codable {
        var path: AgentPath
        var status: AgentStatus
        var parent: AgentPath?
        var createdAt: Double
        var sealedResult: Data?
        var sealedError: Data?
    }

    private func loaded() -> [String: AgentRecord] {
        if let cache { return cache }
        var result: [String: AgentRecord] = [:]
        if let data = try? Data(contentsOf: url) {
            if let wires = try? JSONDecoder().decode([Wire].self, from: data) {
                for w in wires {
                    result[w.path.raw] = AgentRecord(
                        path: w.path, status: w.status,
                        result: w.sealedResult.flatMap(open),
                        error: w.sealedError.flatMap(open),
                        parent: w.parent, createdAt: w.createdAt)
                }
            } else {
                // The file exists but is unreadable (truncated/corrupt). Don't
                // silently obliterate it on the next put — preserve it for
                // forensics (mirrors the StateDB corruption-recovery policy).
                let backup = url.appendingPathExtension(
                    "corrupt-\(ProcessInfo.processInfo.processIdentifier)")
                try? FileManager.default.moveItem(at: url, to: backup)
            }
        }
        cache = result
        return result
    }

    private func persist(_ records: [String: AgentRecord]) {
        let wires = records.values.map { r in
            Wire(path: r.path, status: r.status, parent: r.parent,
                 createdAt: r.createdAt,
                 sealedResult: r.result.flatMap(seal),
                 sealedError: r.error.flatMap(seal))
        }.sorted { $0.path.raw < $1.path.raw }
        guard let data = try? JSONEncoder().encode(wires) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: tmp.path)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            // `replaceItemAt` preserves the DESTINATION's permissions, so the
            // 0600 set on `tmp` is discarded once a destination already exists.
            // Re-assert 0600 on the final path so a pre-existing looser-perm file
            // (umask, older build, restored backup) cannot stay world-readable.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: - Crypto

    private func seal(_ plaintext: String) -> Data? {
        guard let box = try? AES.GCM.seal(Data(plaintext.utf8), using: key) else { return nil }
        return box.combined
    }

    private func open(_ sealed: Data) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
