import Foundation
import IPC
import ProtocolModel
import WireProtocol

/// App-server attestation bridge for spawned workers. A model client asks for
/// an upstream `x-oai-attestation` header just before opening a Responses
/// request; the worker emits `attestation/generate` to the subscribed desktop
/// client and wraps the client's opaque token in the Codex app-server envelope.
public actor WorkerAttestationBroker {
    private enum Status: Int {
        case ok = 0
        case timeout = 1
        case requestFailed = 2
        case requestCanceled = 3
        case malformedResponse = 4
    }

    private struct AttestationEnvelope: Encodable {
        let v = 1
        let s: Int
        let t: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(v, forKey: .v)
            try container.encode(s, forKey: .s)
            try container.encodeIfPresent(t, forKey: .t)
        }

        private enum CodingKeys: String, CodingKey {
            case v, s, t
        }
    }

    private let timeout: Duration
    private var pending: [String: CheckedContinuation<WorkerServerResponse, Never>] = [:]

    public init(timeout: Duration = .milliseconds(100)) {
        self.timeout = timeout
    }

    public func header(for threadId: String, link: WorkerLink) async -> String? {
        let requestId = "attestation-\(UUID().uuidString)"
        let timeout = self.timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(WorkerServerResponse(requestId: requestId,
                                                     result: nil,
                                                     failed: false))
        }
        let response = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkerServerResponse, Never>) in
            pending[requestId] = continuation
            link.sendToSupervisor(.serverRequest(.attestationGenerate(
                .string(requestId),
                AttestationGenerateParams())))
        }
        timeoutTask.cancel()

        if response.failed {
            return Self.envelope(status: .requestFailed)
        }
        guard let result = response.result else {
            return Self.envelope(status: .timeout)
        }
        if result.isNull {
            return nil
        }
        guard let token = result["token"]?.stringValue,
              !token.isEmpty else {
            return Self.envelope(status: .malformedResponse)
        }
        return Self.envelope(status: .ok, token: token)
    }

    @discardableResult
    public func resolve(_ response: WorkerServerResponse) -> Bool {
        guard let continuation = pending.removeValue(forKey: response.requestId) else {
            return false
        }
        continuation.resume(returning: response)
        return true
    }

    private static func envelope(status: Status, token: String? = nil) -> String? {
        let envelope = AttestationEnvelope(s: status.rawValue, t: token)
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
