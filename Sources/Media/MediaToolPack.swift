import Foundation
import HarnessCore
import Tools

/// ADDONS Phase 0 #2 seam for #8: contributes `media_generate` to the router.
/// Gated by `[features].media`; self-prunes until a `MediaTaskLedger` (with at
/// least one provider) is wired.
public struct MediaToolPack: ToolPack {
    public let id = "media"
    private let ledger: MediaTaskLedger?

    public init(ledger: MediaTaskLedger?) { self.ledger = ledger }

    public func tools() -> [any Tool] {
        guard let ledger else { return [] }
        return [MediaGenerateTool(ledger: ledger)]
    }
}
