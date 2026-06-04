import Foundation

// ADDONS.md #1(d) — durable per-conversation thread mapping. A chat must resume
// ITS OWN agent thread across daemon restarts: the same `(channelId,
// conversationId)` always maps to the same `threadId`, so history/context never
// bleeds between conversations and survives a reboot. Backed by a small JSON
// file under `$CODEX_HOME`; an actor serialises the read-modify-write.

public actor ChannelThreadStore {
    private let path: String
    private var map: [String: String]
    private let mint: @Sendable () -> String

    /// - path: JSON file backing the map (created on first write).
    /// - mint: factory for a fresh threadId when a conversation is first seen.
    public init(path: String,
                mint: @escaping @Sendable () -> String = { "ch-" + UUID().uuidString }) {
        self.path = path
        self.mint = mint
        self.map = Self.load(path)
    }

    /// The stable threadId for a conversation, minting + persisting one on first
    /// sight. The key namespaces by channel so two transports that reuse a
    /// conversationId never collide.
    public func threadId(channelId: String, conversationId: String) -> String {
        let key = Self.key(channelId, conversationId)
        if let t = map[key] { return t }
        let t = mint()
        map[key] = t
        persist()
        return t
    }

    /// Look up without minting (nil if the conversation has never run).
    public func existingThreadId(channelId: String, conversationId: String) -> String? {
        map[Self.key(channelId, conversationId)]
    }

    public func count() -> Int { map.count }

    /// Length-prefix the channelId so the key is INJECTIVE: a bare
    /// `channelId + "/" + conversationId` collides (`("a/b","c")` and
    /// `("a","b/c")` both → `a/b/c`), bleeding two conversations into one thread.
    /// `"N:<channelId>/<conversationId>"` — the channelId occupies exactly N
    /// characters after the first `:`, so the split is unambiguous.
    static func key(_ channelId: String, _ conversationId: String) -> String {
        "\(channelId.count):\(channelId)/\(conversationId)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func load(_ path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }
}
