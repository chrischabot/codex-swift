import Foundation

// ADDONS.md #8 — the async media suite. Generative media (image/video/music/tts)
// is SLOW, so a turn must not block on it: `submit` either inlines a fast result
// or persists a `.queued` task and returns a task_id; a supervisor-resident
// poller drives it to completion, writes the asset under the media root, mints a
// signed MediaToken URL, and delivers via push (#7). This file is the ledger +
// lifecycle (pure + testable); untrusted INBOUND media (pdf_read/transcribe)
// goes through the Phase 0 #6 sandboxed decoder, never decoded in-process.

public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case image, video, music, speech
}

public enum MediaTaskStatus: String, Sendable, Codable, Equatable {
    case queued, running, done, failed
}

public struct MediaTask: Sendable, Codable, Equatable {
    public var id: String
    public var kind: MediaKind
    public var provider: String
    public var prompt: String
    public var status: MediaTaskStatus
    /// The provider's own task handle while queued (for polling).
    public var providerTaskId: String?
    /// Local path of the produced asset (set on `.done`).
    public var assetPath: String?
    public var idempotencyKey: String?
    /// A push target (#7) the result is delivered to on completion.
    public var deliverTo: String?
    public var error: String?
    public var createdAt: Int64
    public var deliveredAt: Int64?
    /// Delivery attempts so far — bounds re-delivery so a permanently-bad
    /// deliverTo doesn't retry forever (delivery is decoupled from terminal
    /// status, so a transient push failure is retried, not silently dropped).
    public var deliveryAttempts: Int

    public init(id: String, kind: MediaKind, provider: String, prompt: String,
                status: MediaTaskStatus = .queued, providerTaskId: String? = nil,
                assetPath: String? = nil, idempotencyKey: String? = nil,
                deliverTo: String? = nil, error: String? = nil,
                createdAt: Int64, deliveredAt: Int64? = nil, deliveryAttempts: Int = 0) {
        self.id = id; self.kind = kind; self.provider = provider; self.prompt = prompt
        self.status = status; self.providerTaskId = providerTaskId; self.assetPath = assetPath
        self.idempotencyKey = idempotencyKey; self.deliverTo = deliverTo; self.error = error
        self.createdAt = createdAt; self.deliveredAt = deliveredAt; self.deliveryAttempts = deliveryAttempts
    }

    public var isTerminal: Bool { status == .done || status == .failed }
}

/// What a provider returns from `submit`: an immediate asset (fast path, e.g.
/// OpenAI images) or a queued handle to poll.
public enum MediaSubmitResult: Sendable, Equatable {
    case inline(assetPath: String)
    case queued(providerTaskId: String)
    case failed(String)
}

public enum MediaPollResult: Sendable, Equatable {
    case pending
    case done(assetPath: String)
    case failed(String)
}

/// A generative-media backend (OpenAI images, fal, etc.).
public protocol MediaProvider: Sendable {
    var id: String { get }
    func supports(_ kind: MediaKind) -> Bool
    func submit(kind: MediaKind, prompt: String) async -> MediaSubmitResult
    func poll(providerTaskId: String) async -> MediaPollResult
}
