import Foundation

// Audit Pass 4 — provenance classification (§5.D). PURE: classify how completely an
// output can be REPLAYED from its sources. A source is replayable when its immutable
// raw chain is intact (the raw doc is present AND its content_sha is known, so the
// exact bytes the claim was extracted from can be re-derived). An output is then:
//   replayable — every compiled-from source is replayable
//   partial    — some sources replayable, some not (or absent)
//   missing    — no source is replayable (the chain is gone)

public enum ProvenanceClass: String, Sendable, Equatable {
    case replayable, partial, missing
}

/// One source's raw-chain signals (read from document/source_meta rows).
public struct ProvenanceSource: Sendable, Equatable {
    public var id: Int64
    public var hasRawDoc: Bool       // the immutable raw document row still exists
    public var hasContentSHA: Bool   // its content_sha is recorded (bytes re-derivable)
    public init(id: Int64, hasRawDoc: Bool, hasContentSHA: Bool) {
        self.id = id; self.hasRawDoc = hasRawDoc; self.hasContentSHA = hasContentSHA
    }
    public var isReplayable: Bool { hasRawDoc && hasContentSHA }
}

public enum ProvenanceClassifier {

    /// Classify one output from the set of source ids it was compiled from. An empty
    /// dependency list is `missing` (nothing to replay from). Sources absent from the
    /// index count as not-replayable.
    public static func classify(sourceIDs: [Int64], sources: [Int64: ProvenanceSource]) -> ProvenanceClass {
        guard !sourceIDs.isEmpty else { return .missing }
        var replayable = 0
        for id in sourceIDs where sources[id]?.isReplayable == true { replayable += 1 }
        if replayable == sourceIDs.count { return .replayable }
        if replayable == 0 { return .missing }
        return .partial
    }

    public static func scan(outputs: [(id: Int64, sourceIDs: [Int64])],
                            sources: [Int64: ProvenanceSource]) -> [Int64: ProvenanceClass] {
        var out: [Int64: ProvenanceClass] = [:]
        for o in outputs { out[o.id] = classify(sourceIDs: o.sourceIDs, sources: sources) }
        return out
    }

    public static func index(_ sources: [ProvenanceSource]) -> [Int64: ProvenanceSource] {
        Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
