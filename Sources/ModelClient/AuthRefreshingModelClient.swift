import Foundation
import InfraPrimitives

/// Retries one HTTP 401 model-open failure after obtaining a fresh bearer token.
///
/// The token provider is intentionally injected so production can route through
/// `AuthManager`/broker, while tests can prove the retry contract without
/// binding `ModelClient` to the Auth module.
public actor AuthRefreshingModelClient: ModelClient {
    public typealias RefreshToken = @Sendable () async -> String?
    public typealias MakeClient = @Sendable (String) -> any ModelClient

    private let initial: any ModelClient
    private let refreshToken: RefreshToken
    private let makeClient: MakeClient
    private let refreshFlight = SingleFlight<String, String>()
    private var refreshed: (token: String, client: any ModelClient)?

    public init(initial: any ModelClient,
                refreshToken: @escaping RefreshToken,
                makeClient: @escaping MakeClient) {
        self.initial = initial
        self.refreshToken = refreshToken
        self.makeClient = makeClient
    }

    public func stream(_ prompt: Prompt,
                       _ settings: ModelSettings) async throws -> ResponseStream {
        do {
            return try await activeClient().stream(prompt, settings)
        } catch let e as ModelError where e.httpStatus == 401 {
            guard let retry = try await refreshedClientAfter401() else { throw e }
            return try await retry.stream(prompt, settings)
        }
    }

    public func compactConversationHistory(_ prompt: Prompt, _ settings: ModelSettings)
    async throws -> [RemoteCompaction.OutputMessage]? {
        do {
            return try await activeClient().compactConversationHistory(prompt, settings)
        } catch let e as ModelError where e.httpStatus == 401 {
            guard let retry = try await refreshedClientAfter401() else { throw e }
            return try await retry.compactConversationHistory(prompt, settings)
        }
    }

    private func activeClient() -> any ModelClient {
        refreshed?.client ?? initial
    }

    private func refreshedClientAfter401() async throws -> (any ModelClient)? {
        let refresh = refreshToken
        let token = try await refreshFlight.run("auth") {
            guard let token = await refresh(), !token.isEmpty else {
                throw ModelError("auth refresh returned no access token",
                                 retryable: false, httpStatus: 401)
            }
            return token
        }
        if let current = refreshed, current.token == token {
            return current.client
        }
        let client = makeClient(token)
        refreshed = (token, client)
        return client
    }
}
