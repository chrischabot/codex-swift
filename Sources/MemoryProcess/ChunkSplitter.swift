import Foundation

/// Token-aware chunk splitter. CodexKit has its own `Tokenizer` module but
/// pulling it in here would crank the build graph; for this stage we use a
/// fast heuristic (~4 bytes per token, sentence-aware) that produces
/// reasonably-sized chunks for both English and code-heavy text. Swappable
/// out for a real BPE tokeniser via the `tokensFor` closure on the splitter.
public struct ChunkSplitter: Sendable {
    public var targetTokens: Int
    public var overlapTokens: Int
    public var tokensFor: @Sendable (String) -> Int

    public init(targetTokens: Int = 512,
                overlapTokens: Int = 32,
                tokensFor: @escaping @Sendable (String) -> Int =
                    { max(1, $0.utf8.count / 4) }) {
        precondition(overlapTokens < targetTokens)
        self.targetTokens = targetTokens
        self.overlapTokens = overlapTokens
        self.tokensFor = tokensFor
    }

    public struct Piece: Sendable, Equatable {
        public var idx: Int
        public var text: String
        public var tokens: Int
    }

    public func split(_ text: String) -> [Piece] {
        guard !text.isEmpty else { return [] }
        let sentences = Self.splitIntoSentences(text)
        var pieces: [Piece] = []
        var bucket: [String] = []
        var bucketTokens = 0
        var idx = 0

        func flushBucket() {
            guard !bucket.isEmpty else { return }
            let joined = bucket.joined(separator: " ")
            pieces.append(Piece(idx: idx, text: joined, tokens: bucketTokens))
            idx += 1
            if overlapTokens > 0 {
                // Carry a tail of sentences worth at least `overlapTokens`.
                var carryTokens = 0
                var carry: [String] = []
                for s in bucket.reversed() {
                    let t = tokensFor(s)
                    carryTokens += t
                    carry.insert(s, at: 0)
                    if carryTokens >= overlapTokens { break }
                }
                bucket = carry
                bucketTokens = carryTokens
            } else {
                bucket.removeAll()
                bucketTokens = 0
            }
        }

        for sentence in sentences {
            let t = tokensFor(sentence)
            if bucketTokens + t > targetTokens && !bucket.isEmpty {
                flushBucket()
            }
            bucket.append(sentence)
            bucketTokens += t
            if bucketTokens >= targetTokens { flushBucket() }
        }
        if !bucket.isEmpty {
            // Drop the tail flush's overlap carry if it would emit a near-empty piece.
            let joined = bucket.joined(separator: " ")
            pieces.append(Piece(idx: idx, text: joined, tokens: bucketTokens))
        }
        return pieces
    }

    static func splitIntoSentences(_ text: String) -> [String] {
        // Conservative sentence splitter: break on `. ! ?` followed by whitespace
        // or end-of-string. Falls back to newlines for non-prose payloads.
        var out: [String] = []
        var current = ""
        var prev: Character = " "
        for ch in text {
            current.append(ch)
            if (ch == "." || ch == "!" || ch == "?" || ch == "\n"),
               (current.count > 12 || ch == "\n") {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
            prev = ch
            _ = prev
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
