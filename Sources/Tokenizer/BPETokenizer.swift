import Foundation

/// Byte-level Byte-Pair-Encoding tokenizer (the GPT-2 / `tiktoken` algorithm).
/// The merge table is *data*, not code: drop the real OpenAI table at
/// `$CODEX_HOME/tokenizer/<name>.json` (`{"encoder":{tok:id},"merges":["a b"]}`)
/// and this produces real token ids; with no table, callers use the
/// Codex-faithful byte approximation instead. The algorithm itself is exact
/// and deterministically unit-tested with a synthetic table.
public struct BPETokenizer: TokenCounter, Sendable {
    private let encoder: [String: Int]
    private let bpeRanks: [String: Int]      // "a b" -> rank
    private let byteEncoder: [UInt8: Character]

    public init(encoder: [String: Int], merges: [String]) {
        self.encoder = encoder
        var ranks: [String: Int] = [:]
        for (i, m) in merges.enumerated() { ranks[m] = i }
        self.bpeRanks = ranks
        self.byteEncoder = Self.bytesToUnicode()
    }

    /// GPT-2 reversible byte→unicode mapping (keeps BPE operating on printable
    /// codepoints while remaining lossless over arbitrary bytes).
    static func bytesToUnicode() -> [UInt8: Character] {
        var bs: [Int] = []
        bs += Array(33...126)
        bs += Array(161...172)
        bs += Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) {
            map[UInt8(b)] = Character(UnicodeScalar(UInt32(c))!)
        }
        return map
    }

    /// GPT-2 pre-tokenization pattern.
    private static let pattern =
        "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"

    private func pretokenize(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: Self.pattern) else {
            return text.isEmpty ? [] : [text]
        }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }
    }

    private func getPairs(_ word: [String]) -> Set<String> {
        var pairs = Set<String>()
        guard word.count > 1 else { return pairs }
        for i in 0..<(word.count - 1) { pairs.insert(word[i] + " " + word[i + 1]) }
        return pairs
    }

    /// Standard rank-greedy BPE on one pre-token's symbol sequence.
    private func bpe(_ token: [String]) -> [String] {
        var word = token
        if word.count < 2 { return word }
        while true {
            let pairs = getPairs(word)
            guard let best = pairs.min(by: {
                (bpeRanks[$0] ?? Int.max) < (bpeRanks[$1] ?? Int.max)
            }), bpeRanks[best] != nil else { break }
            let parts = best.split(separator: " ", maxSplits: 1).map(String.init)
            let first = parts[0], second = parts.count > 1 ? parts[1] : ""
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
        }
        return word
    }

    /// Encode to token ids. Unknown merged symbols (not in `encoder`) fall
    /// back to their constituent single-symbol ids when present.
    public func encode(_ text: String) -> [Int] {
        var out: [Int] = []
        for piece in pretokenize(text) {
            let symbols = Array(piece.utf8).map { String(byteEncoder[$0] ?? "?") }
            for sym in bpe(symbols) {
                if let id = encoder[sym] {
                    out.append(id)
                } else {
                    for ch in sym {
                        if let id = encoder[String(ch)] { out.append(id) }
                    }
                }
            }
        }
        return out
    }

    public func countTokens(_ text: String) -> Int { encode(text).count }

    /// Load a tokenizer table from disk; nil when absent/malformed so callers
    /// fall back to the Codex-parity approximation.
    public static func load(codexHome: String, name: String) -> BPETokenizer? {
        let path = codexHome + "/tokenizer/\(name).json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        struct Table: Decodable { var encoder: [String: Int]; var merges: [String] }
        guard let t = try? JSONDecoder().decode(Table.self, from: data) else { return nil }
        return BPETokenizer(encoder: t.encoder, merges: t.merges)
    }
}

/// Resolves a token counter for a model: a loaded BPE table when present,
/// else the Codex-faithful approximation (the default — preserves parity).
public enum TokenCounting {
    public static func resolve(codexHome: String, tokenizerName: String?)
    -> any TokenCounter {
        if let name = tokenizerName,
           let bpe = BPETokenizer.load(codexHome: codexHome, name: name) {
            return bpe
        }
        return ApproxTokenCounter()
    }
}