import Foundation
import InfraPrimitives

/// A document handed off from the normaliser to MemoryProcess. Carries the
/// raw bytes' canonical form, the source URI, and the metadata needed to
/// build the `DocumentRow` plus subsequent chunks.
public struct IngestedDocument: Sendable, Equatable {
    public var sourceName: String
    public var sourceKind: SourceSpec.Kind
    public var sourceURI: String
    public var title: String?
    public var publishedAt: Int64?
    public var fetchedAt: Int64
    public var canonicalText: String
    public var rawBytes: Int64
    public var contentSHA: Data

    public init(sourceName: String, sourceKind: SourceSpec.Kind,
                sourceURI: String, title: String?, publishedAt: Int64?,
                fetchedAt: Int64, canonicalText: String,
                rawBytes: Int64, contentSHA: Data) {
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.sourceURI = sourceURI
        self.title = title
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.canonicalText = canonicalText
        self.rawBytes = rawBytes
        self.contentSHA = contentSHA
    }
}

/// Bounded fan-in ring between the ingest pipeline and MemoryProcess. Wraps
/// the standard `BoundedChannel`; the capacity defaults to 1024 chunk-batches
/// per §4 of the design doc.
public actor ChunkRing {
    public let capacity: Int
    private let channel: BoundedChannel<IngestedDocument>

    public init(capacity: Int = 1024) {
        self.capacity = capacity
        self.channel = BoundedChannel<IngestedDocument>(
            capacity: capacity, policy: .block)
    }

    public func enqueue(_ doc: IngestedDocument) async throws {
        try await channel.send(doc)
    }

    public func dequeue() async -> IngestedDocument? {
        await channel.receive()
    }

    /// Drain whatever is currently buffered without ever parking. The main
    /// daemon loop uses this so a quiescent ring doesn't deadlock the
    /// scheduler — a blocking `dequeue()` would suspend forever between
    /// ticks because the channel stays open. Returns nil when the ring is
    /// empty right now (callers loop until nil, then go back to tick).
    public func tryDequeue() async -> IngestedDocument? {
        await channel.tryReceive()
    }

    public func close() async {
        await channel.close()
    }

    public func depth() async -> Int { await channel.depth() }

    public func saturation() async -> Double { await channel.saturation() }
}
