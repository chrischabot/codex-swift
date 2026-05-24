import Foundation

/// Records every request and forwards to the wrapped client. Used by live
/// tests to assert `prompt_cache_key`/`threadId` stability and prompt
/// fidelity against the real provider.
public actor RecordingModelClient: ModelClient {
    public struct Captured: Sendable, Equatable {
        public let prompt: Prompt
        public let settings: ModelSettings
    }

    private let inner: any ModelClient
    public private(set) var captured: [Captured] = []

    public init(_ inner: any ModelClient) { self.inner = inner }

    public func stream(_ prompt: Prompt,
                       _ settings: ModelSettings) async throws -> ResponseStream {
        captured.append(Captured(prompt: prompt, settings: settings))
        return try await inner.stream(prompt, settings)
    }

    public func capturedRequests() -> [Captured] { captured }
}