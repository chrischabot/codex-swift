import Foundation
import HarnessCore
import Tools

/// ADDONS Phase 0 #2 seam for #4: contributes `google_api` to the router. Gated
/// by `[features].google`; self-prunes until a `GoogleAPIClient` (with the OAuth
/// connector) is wired.
public struct GoogleToolPack: ToolPack {
    public let id = "google"
    private let client: GoogleAPIClient?

    public init(client: GoogleAPIClient?) { self.client = client }

    public func tools() -> [any Tool] {
        guard let client else { return [] }
        return [GoogleAPITool(client: client)]
    }
}
