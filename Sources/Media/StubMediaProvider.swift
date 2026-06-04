import Foundation

/// The deny-default MVP provider: synchronous (inline) generation that writes a
/// small placeholder asset under `mediaRoot` and returns its path immediately.
/// Because it is INLINE, delivery completes inside `submit` with no poller — so
/// the media tool works in BOTH the in-process and the spawned worker mode.
///
/// A real async backend (OpenAI Images / fal) is a `.queued` provider that needs
/// the daemon-resident `MediaPoller` to drive `poll` → `done`; that path only
/// works under in-process workers (the spawned worker is a separate process the
/// daemon poller can't reach). The OpenAIImagesProvider skeleton below documents
/// the shape without shipping a live, key-burning network call.
public struct StubMediaProvider: MediaProvider {
    public let id = "stub"
    private let mediaRoot: String

    public init(mediaRoot: String) { self.mediaRoot = mediaRoot }

    public func supports(_ kind: MediaKind) -> Bool { true }

    public func submit(kind: MediaKind, prompt: String) async -> MediaSubmitResult {
        // Write a tiny placeholder file so the asset PATH is real (the gateway
        // /media route can serve it once signed-URL delivery is wired). The name
        // is unguessable; the extension marks it a stub.
        let name = "\(kind.rawValue)-\(UUID().uuidString).stub.txt"
        let path = mediaRoot + "/" + name
        let body = "stub \(kind.rawValue) for prompt: \(prompt)\n"
        do {
            try FileManager.default.createDirectory(
                atPath: mediaRoot, withIntermediateDirectories: true)
            try body.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        } catch {
            return .failed("stub write failed: \(error)")
        }
        return .inline(assetPath: path)
    }

    public func poll(providerTaskId: String) async -> MediaPollResult { .pending }
}

/// Builds the concrete provider named in `[media].provider`. Returns nil for an
/// unknown provider (deny-default — the caller treats nil as "not configured").
public enum MediaProviderFactory {
    public static func make(_ cfg: MediaConfig) -> (any MediaProvider)? {
        switch cfg.provider {
        case "stub": return StubMediaProvider(mediaRoot: cfg.mediaRoot)
        // case "openai": return OpenAIImagesProvider(...)  // async; needs poller
        default: return nil
        }
    }
}
