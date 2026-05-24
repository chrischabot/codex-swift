import Foundation

/// Counts model-visible tokens for a piece of text. The harness uses this for
/// the auto-compact ladder and skills budget.
public protocol TokenCounter: Sendable {
    func countTokens(_ text: String) -> Int
}

/// Codex parity default: `approx_token_count` = ceil(utf8_bytes / 4). This is
/// exactly what `codex_utils_output_truncation` / `context_manager` use, so
/// the estimate path stays byte-for-byte faithful to upstream. A real BPE
/// (`BPETokenizer`) is available but opt-in to avoid diverging from Codex.
public struct ApproxTokenCounter: TokenCounter {
    public init() {}
    public func countTokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }
}