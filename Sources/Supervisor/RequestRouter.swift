import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WireProtocol
import ProtocolModel
import Persistence
import InfraPrimitives
import Skills
import MCP
import Auth
import Tokenizer
import Config
import Observability
import Connectors
import IPC
import Tools
import Prompts
import ModelClient
import Push
import Cron
import Channels

/// Wire<->domain mapping for the #6 cron RPC. Lives in Supervisor (the only place
/// that imports BOTH ProtocolModel and Cron) so ProtocolModel stays a leaf and
/// Cron stays dependency-light.
extension CronScheduleWire {
    /// Validate + project to the domain Schedule (nil → invalid request).
    func toSchedule() -> Schedule? {
        switch kind {
        case "at":    guard let at else { return nil }; return .at(at)
        case "every": guard let every, every > 0 else { return nil }; return .every(every)
        case "cron":  guard let cron, !cron.isEmpty else { return nil }; return .cron(cron)
        default:      return nil
        }
    }
    init(_ s: Schedule) {
        switch s {
        case .at(let t):    self.init(kind: "at", at: t)
        case .every(let n): self.init(kind: "every", every: n)
        case .cron(let e):  self.init(kind: "cron", cron: e)
        }
    }
}
extension CronJobWire {
    init(_ j: CronJob) {
        self.init(id: j.id, schedule: CronScheduleWire(j.schedule), prompt: j.prompt,
                  enabled: j.enabled, skipMemory: j.skipMemory, deliverTo: j.deliverTo,
                  lastRunAt: j.lastRunAt, createdAt: j.createdAt)
    }
}

private struct SimpleError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AccountNudgeEmailHTTPStatusError: Error, LocalizedError {
    let statusCode: Int
    var errorDescription: String? { "HTTP \(statusCode)" }
}

/// Per-connection request router (Codex `message_processor` analog). Enforces
/// the initialize handshake and experimental gating, then dispatches the
/// complete Codex app-server method surface to the store and the per-thread
/// worker. It owns the single wire-schema source (port-eval §2.5 / rework
/// §6.2).
///
/// ACCEPTED DIVERGENCE — per-scope request serialization (app-server-registry/finding-1).
/// Upstream `app-server` attaches a `serialization:` scope to every method
/// (app-server-protocol/src/protocol/common.rs:445-1056 — e.g.
/// `thread_id(params.thread_id)`, `global("config")`, `global("account-auth")`,
/// `command_process_id`, `fs_watch_id`) and message_processor.rs:804,831-840
/// enqueues handlers via `RequestSerializationQueueKey::from_scope`, so
/// same-scope requests run strictly serially while different scopes — and
/// `serialization: None` methods — run concurrently.
///
/// This Swift port INTENTIONALLY OMITS the scope-keyed serialization queue.
/// `RequestRouter` is a single `actor`, which serializes request ENTRY but
/// yields at every `await`, so two in-flight same-scope requests (e.g.
/// concurrent `config/value/write`, or two `turn/start` on one thread) can
/// interleave at await points. The defense-in-depth that makes this acceptable:
///   1. actor entry-serialization means contention is rare for low-traffic
///      scopes (`global("account-auth")`, `global("mcp-registry")`,
///      `global("windows-sandbox-setup")`); and
///   2. config writes carry an `expectedVersion` optimistic-concurrency check
///      (see `RequestRouter.swift` config-write handling, ~line 1973 and the
///      version-compare helper ~line 6121-6168) that prevents silent data loss.
/// The combination is adequate for the corruption-prevention goal. Strict
/// wire-shape ordering parity (if ever required, e.g. by a request-ordering
/// test harness) would require introducing a per-connection
/// `ClientRequestSerializationScope` analogue (thread_id / global(name) /
/// command_process_id / fs_watch_id / fuzzy_session_id) so same-scope handlers
/// await each other while None-scope methods stay concurrent.
public actor RequestRouter {
    private static let remoteControlSegmentTargetBytes = 100 * 1024
    private static let remoteControlSegmentMaxBytes = 150 * 1024
    private static let remoteControlReassembledMaxBytes = 100 * 1024 * 1024
    private static let remoteControlSegmentCountMax = 1024
    private static let remoteControlSegmentAssemblyMaxCount = 128

    public struct RemoteControlEnrollment: Sendable, Equatable {
        public var serverId: String
        public var environmentId: String

        public init(serverId: String, environmentId: String) {
            self.serverId = serverId
            self.environmentId = environmentId
        }
    }

    public struct RemoteControlTarget: Sendable, Equatable {
        public var websocketURL: String
        public var enrollURL: String

        public init(websocketURL: String, enrollURL: String) {
            self.websocketURL = websocketURL
            self.enrollURL = enrollURL
        }
    }

    public struct RemoteControlWebSocketRequest: Sendable, Equatable {
        public var websocketURL: String
        public var accessToken: String
        public var accountId: String?
        public var serverId: String
        public var serverName: String
        public var installationId: String

        public init(websocketURL: String, accessToken: String, accountId: String?,
                    serverId: String, serverName: String, installationId: String) {
            self.websocketURL = websocketURL
            self.accessToken = accessToken
            self.accountId = accountId
            self.serverId = serverId
            self.serverName = serverName
            self.installationId = installationId
        }
    }

    public enum RemoteControlClientEvent: Sendable, Equatable, Codable {
        case clientMessage(JSONRPCMessage)
        case clientMessageChunk(segmentId: Int, segmentCount: Int,
                                messageSizeBytes: Int, messageChunkBase64: String)
        case ack(segmentId: Int?)
        case ping
        case clientClosed

        private enum CodingKeys: String, CodingKey {
            case type
            case message
            case segmentId = "segment_id"
            case segmentCount = "segment_count"
            case messageSizeBytes = "message_size_bytes"
            case messageChunkBase64 = "message_chunk_base64"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "client_message":
                self = .clientMessage(try container.decode(JSONRPCMessage.self, forKey: .message))
            case "client_message_chunk":
                self = .clientMessageChunk(
                    segmentId: try container.decode(Int.self, forKey: .segmentId),
                    segmentCount: try container.decode(Int.self, forKey: .segmentCount),
                    messageSizeBytes: try container.decode(Int.self, forKey: .messageSizeBytes),
                    messageChunkBase64: try container.decode(
                        String.self, forKey: .messageChunkBase64))
            case "ack":
                self = .ack(segmentId: try container.decodeIfPresent(Int.self, forKey: .segmentId))
            case "ping":
                self = .ping
            case "client_closed":
                self = .clientClosed
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "unknown remote-control client event type \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .clientMessage(let message):
                try container.encode("client_message", forKey: .type)
                try container.encode(message, forKey: .message)
            case .clientMessageChunk(let segmentId, let segmentCount,
                                     let messageSizeBytes, let messageChunkBase64):
                try container.encode("client_message_chunk", forKey: .type)
                try container.encode(segmentId, forKey: .segmentId)
                try container.encode(segmentCount, forKey: .segmentCount)
                try container.encode(messageSizeBytes, forKey: .messageSizeBytes)
                try container.encode(messageChunkBase64, forKey: .messageChunkBase64)
            case .ack(let segmentId):
                try container.encode("ack", forKey: .type)
                try container.encodeIfPresent(segmentId, forKey: .segmentId)
            case .ping:
                try container.encode("ping", forKey: .type)
            case .clientClosed:
                try container.encode("client_closed", forKey: .type)
            }
        }
    }

    public struct RemoteControlClientEnvelope: Sendable, Equatable, Codable {
        public var event: RemoteControlClientEvent
        public var clientId: String
        public var streamId: String?
        public var seqId: UInt64?
        public var cursor: String?

        private enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case streamId = "stream_id"
            case seqId = "seq_id"
            case cursor
        }

        public init(event: RemoteControlClientEvent, clientId: String,
                    streamId: String? = nil, seqId: UInt64? = nil,
                    cursor: String? = nil) {
            self.event = event
            self.clientId = clientId
            self.streamId = streamId
            self.seqId = seqId
            self.cursor = cursor
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.event = try RemoteControlClientEvent(from: decoder)
            self.clientId = try container.decode(String.self, forKey: .clientId)
            self.streamId = try container.decodeIfPresent(String.self, forKey: .streamId)
            self.seqId = try container.decodeIfPresent(UInt64.self, forKey: .seqId)
            self.cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        }

        public func encode(to encoder: any Encoder) throws {
            try event.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(clientId, forKey: .clientId)
            try container.encodeIfPresent(streamId, forKey: .streamId)
            try container.encodeIfPresent(seqId, forKey: .seqId)
            try container.encodeIfPresent(cursor, forKey: .cursor)
        }
    }

    public enum RemoteControlServerEvent: Sendable, Equatable, Codable {
        case serverMessage(JSONRPCMessage)
        case serverMessageChunk(segmentId: Int, segmentCount: Int,
                                messageSizeBytes: Int, messageChunkBase64: String)
        case pong(status: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case message
            case segmentId = "segment_id"
            case segmentCount = "segment_count"
            case messageSizeBytes = "message_size_bytes"
            case messageChunkBase64 = "message_chunk_base64"
            case status
        }

        fileprivate var segmentId: Int? {
            switch self {
            case .serverMessageChunk(let segmentId, _, _, _): return segmentId
            case .serverMessage, .pong: return nil
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "server_message":
                self = .serverMessage(try container.decode(JSONRPCMessage.self, forKey: .message))
            case "server_message_chunk":
                self = .serverMessageChunk(
                    segmentId: try container.decode(Int.self, forKey: .segmentId),
                    segmentCount: try container.decode(Int.self, forKey: .segmentCount),
                    messageSizeBytes: try container.decode(Int.self, forKey: .messageSizeBytes),
                    messageChunkBase64: try container.decode(
                        String.self, forKey: .messageChunkBase64))
            case "pong":
                self = .pong(status: try container.decode(String.self, forKey: .status))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "unknown remote-control server event type \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .serverMessage(let message):
                try container.encode("server_message", forKey: .type)
                try container.encode(message, forKey: .message)
            case .serverMessageChunk(let segmentId, let segmentCount,
                                     let messageSizeBytes, let messageChunkBase64):
                try container.encode("server_message_chunk", forKey: .type)
                try container.encode(segmentId, forKey: .segmentId)
                try container.encode(segmentCount, forKey: .segmentCount)
                try container.encode(messageSizeBytes, forKey: .messageSizeBytes)
                try container.encode(messageChunkBase64, forKey: .messageChunkBase64)
            case .pong(let status):
                try container.encode("pong", forKey: .type)
                try container.encode(status, forKey: .status)
            }
        }
    }

    public struct RemoteControlServerEnvelope: Sendable, Equatable, Codable {
        public var event: RemoteControlServerEvent
        public var clientId: String
        public var streamId: String
        public var seqId: UInt64

        private enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case streamId = "stream_id"
            case seqId = "seq_id"
        }

        public init(event: RemoteControlServerEvent, clientId: String,
                    streamId: String, seqId: UInt64) {
            self.event = event
            self.clientId = clientId
            self.streamId = streamId
            self.seqId = seqId
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.event = try RemoteControlServerEvent(from: decoder)
            self.clientId = try container.decode(String.self, forKey: .clientId)
            self.streamId = try container.decode(String.self, forKey: .streamId)
            self.seqId = try container.decode(UInt64.self, forKey: .seqId)
        }

        public func encode(to encoder: any Encoder) throws {
            try event.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(clientId, forKey: .clientId)
            try container.encode(streamId, forKey: .streamId)
            try container.encode(seqId, forKey: .seqId)
        }
    }

    public final class RemoteControlWebSocketConnection: @unchecked Sendable {
        public var incoming: AsyncStream<RemoteControlClientEnvelope>
        public var sendEnvelope: @Sendable (RemoteControlServerEnvelope) async throws -> Void
        public var ping: @Sendable () async throws -> Void
        public var close: @Sendable () async -> Void

        public init(
            incoming: AsyncStream<RemoteControlClientEnvelope> = AsyncStream { _ in },
            sendEnvelope: @escaping @Sendable (RemoteControlServerEnvelope) async throws -> Void = { _ in },
            ping: @escaping @Sendable () async throws -> Void = {},
            close: @escaping @Sendable () async -> Void
        ) {
            self.incoming = incoming
            self.sendEnvelope = sendEnvelope
            self.ping = ping
            self.close = close
        }
    }

    public typealias AccountRateLimitsFetcher = @Sendable (_ tokens: AuthTokens, _ baseURL: String) async throws -> JSONValue
    public typealias AccountTokenUsageFetcher = @Sendable (_ tokens: AuthTokens, _ baseURL: String) async throws -> GetAccountTokenUsageResponse
    public typealias AccountNudgeEmailSender = @Sendable (_ tokens: AuthTokens, _ baseURL: String, _ creditType: String) async throws -> String
    public typealias RemoteControlEnroller = @Sendable (_ tokens: AuthTokens, _ baseURL: String, _ installationId: String, _ serverName: String) async throws -> RemoteControlEnrollment
    public typealias RemoteControlWebSocketConnector = @Sendable (_ request: RemoteControlWebSocketRequest) async throws -> RemoteControlWebSocketConnection

    private let supervisor: SessionSupervisor
    private let store: ThreadStore
    /// Owner-boundary flag (ADDONS #7). codex-swift has no per-RPC owner token —
    /// the owner boundary IS the transport. The daemon-level router (stdio / UDS
    /// / loopback socket) is owner-trusted (true); the per-tab WebGateway routers
    /// are a LOWER trust tier (false). Owner-only methods like `outbound/send`
    /// refuse when this is false. Default true so all existing call sites stay
    /// owner-trusted; the WebGateway routerFactory MUST pass false.
    private let allowsOwnerOnlyRPC: Bool
    private let gate = ExperimentalGate()
    private var caps = ClientCapabilities()
    private var initialized = false
    private let codexHome: String
    private let auth: AuthManager?
    private let config: Config?
    private let requirementsLoader: ConfigRequirementsLoader
    private let accountRateLimitsFetcher: AccountRateLimitsFetcher
    /// Best-effort token-usage profile fetcher (`account/usage/read`). Backend
    /// HTTP by default; the auth-gate precondition runs in the handler. Stored as
    /// a property so tests can substitute a deterministic projection.
    private let accountTokenUsageFetcher: AccountTokenUsageFetcher = RequestRouter.fetchAccountTokenUsage
    /// Runtime-registered extra skill roots (`skills/extraRoots/set`). Appended
    /// to the canonical discovery roots on every `skills/list`.
    private var extraSkillRoots: [String] = []
    private let accountNudgeEmailSender: AccountNudgeEmailSender
    private let remoteControlEnroller: RemoteControlEnroller
    private let remoteControlWebSocketConnector: RemoteControlWebSocketConnector
    private let memoryResetHandler: (@Sendable () async -> Void)?
    /// Deny-default read handle into the Memory Wiki store. nil → `wiki/*` RPCs
    /// are refused with "wiki is not enabled". Internal (not private) so the
    /// wiki dispatch carved into RequestRouter+Wiki.swift can reach it.
    let wikiQuery: WikiQueryHandle?
    /// Injected live realtime voice backend (OpenAI Realtime API). When nil,
    /// `thread/realtime/*` uses the built-in echo mock. See RealtimeBackend.swift.
    private let realtimeBackendFactory: RealtimeBackendFactory?
    private let mcpManager = McpManager()
    private let fileWatchManager = FileWatchManager()
    private let skillsChangeWatchManager = SkillsChangeWatchManager()
    private struct PendingDeviceLogin {
        var connection: ObjectIdentifier
        var task: Task<Void, Never>
    }
    private struct PendingBrowserLogin {
        var connection: ObjectIdentifier
        var server: ChatGPTLoginCallbackServer
        var timeoutTask: Task<Void, Never>
    }
    private struct FuzzySearchSessionKey: Hashable {
        var connection: ObjectIdentifier
        var sessionId: String
    }
    private struct FuzzySearchSession {
        var roots: [String]
        var updateTask: Task<Void, Never>?
    }
    private var fuzzySearchSessions: [FuzzySearchSessionKey: FuzzySearchSession] = [:]
    private var subscriptions: [ThreadId: UInt64] = [:]
    private var realtimeSessions: [ThreadId: RealtimeSessionState] = [:]
    /// Live realtime voice sessions (OpenAI Realtime API bridge), keyed by
    /// thread. Populated only when `realtimeBackendFactory` is injected; when
    /// it is nil the `realtimeSessions` echo path above runs instead.
    private var liveRealtimeSessions: [ThreadId: any RealtimeBackendSession] = [:]
    private var pendingDirectServerResponses:
        [String: CheckedContinuation<JSONValue?, Never>] = [:]
    private var pendingLoginIds: [ObjectIdentifier: String] = [:]
    private var pendingBrowserLogins: [String: PendingBrowserLogin] = [:]
    private var pendingDeviceLogins: [String: PendingDeviceLogin] = [:]
    private var runtimeFeatureEnablement: [String: Bool] = [:]
    private var outOfBandElicitationCounts: [ThreadId: Int64] = [:]
    private var remoteEnvironments: [String: String] = [:]
    private struct RemoteControlState: Equatable {
        var status: String
        var serverName: String
        var installationId: String
        var environmentId: String?
    }
    private var remoteControlState: RemoteControlState?
    private var remoteControlGeneration: UInt64 = 0
    private var remoteControlWebSocketConnection: RemoteControlWebSocketConnection?
    private var remoteControlReconnectRequest: RemoteControlWebSocketRequest?
    private struct RemoteControlVirtualClientKey: Hashable {
        var clientId: String
        var streamId: String
    }
    private struct RemoteControlVirtualClient {
        var router: RequestRouter
        var connection: RemoteControlVirtualConnection
        var lastInboundSeqId: UInt64?
        var lastActivityAt: Date
    }
    private var remoteControlVirtualClients:
        [RemoteControlVirtualClientKey: RemoteControlVirtualClient] = [:]
    private var remoteControlLegacyStreamIds: [String: String] = [:]
    private struct RemoteControlClientChunkKey: Hashable {
        var clientId: String
        var streamId: String?
    }
    private var remoteControlLastCompletedClientChunkSeqIds:
        [RemoteControlClientChunkKey: UInt64] = [:]
    private var remoteControlClientSegmentReassembler =
        RemoteControlClientSegmentReassembler()

    private final class RemoteControlOutboundState: @unchecked Sendable {
        private let lock = NSLock()
        private var nextSeqId: UInt64 = 1
        private var buffered: [RemoteControlServerEnvelope] = []

        func makeEnvelopes(event: RemoteControlServerEvent,
                           clientId: String,
                           streamId: String) -> [RemoteControlServerEnvelope] {
            lock.lock()
            defer { lock.unlock() }
            let seqId = nextSeqId
            nextSeqId &+= 1
            let envelope = RemoteControlServerEnvelope(
                event: event,
                clientId: clientId,
                streamId: streamId,
                seqId: seqId)
            let envelopes = Self.splitForTransport(envelope)
            buffered.append(contentsOf: envelopes)
            return envelopes
        }

        func ack(seqId: UInt64, segmentId: Int?) {
            lock.lock()
            defer { lock.unlock() }
            let ackSegment = segmentId ?? Int.max
            buffered.removeAll { envelope in
                let envelopeSegment = envelope.event.segmentId ?? 0
                return envelope.seqId < seqId
                    || (envelope.seqId == seqId && envelopeSegment <= ackSegment)
            }
        }

        func bufferedEnvelopes() -> [RemoteControlServerEnvelope] {
            lock.lock()
            defer { lock.unlock() }
            return buffered
        }

        private static func splitForTransport(
            _ envelope: RemoteControlServerEnvelope
        ) -> [RemoteControlServerEnvelope] {
            guard case .serverMessage(let message) = envelope.event,
                  (try? JSONEncoder().encode(envelope).count)
                    .map({ $0 > RequestRouter.remoteControlSegmentMaxBytes }) == true else {
                return [envelope]
            }
            guard let raw = try? JSONEncoder().encode(message),
                  raw.count <= RequestRouter.remoteControlReassembledMaxBytes else {
                return []
            }
            let messageSizeBytes = raw.count
            let minimalSegmentCount = min(max(messageSizeBytes, 1),
                                          RequestRouter.remoteControlSegmentCountMax)
            let minimalChunk = raw.prefix(min(raw.count, 1))
            if serializedChunkLength(envelope: envelope, segmentId: 0,
                                     segmentCount: minimalSegmentCount,
                                     messageSizeBytes: messageSizeBytes,
                                     chunk: minimalChunk)
                .map({ $0 > RequestRouter.remoteControlSegmentMaxBytes }) ?? true {
                return []
            }

            var segmentCount = max(
                2,
                (messageSizeBytes + RequestRouter.remoteControlSegmentTargetBytes - 1)
                    / RequestRouter.remoteControlSegmentTargetBytes)
            while true {
                let chunkSize = max(1, (messageSizeBytes + segmentCount - 1) / segmentCount)
                segmentCount = (messageSizeBytes + chunkSize - 1) / chunkSize
                let chunks = stride(from: 0, to: messageSizeBytes, by: chunkSize).map {
                    raw[$0..<min($0 + chunkSize, messageSizeBytes)]
                }
                let segmentsFit = chunks.enumerated().allSatisfy { segmentId, chunk in
                    serializedChunkLength(envelope: envelope,
                                          segmentId: segmentId,
                                          segmentCount: segmentCount,
                                          messageSizeBytes: messageSizeBytes,
                                          chunk: chunk)
                        .map({ $0 <= RequestRouter.remoteControlSegmentMaxBytes }) ?? false
                }
                if segmentsFit {
                    return chunks.enumerated().map { segmentId, chunk in
                        RemoteControlServerEnvelope(
                            event: .serverMessageChunk(
                                segmentId: segmentId,
                                segmentCount: segmentCount,
                                messageSizeBytes: messageSizeBytes,
                                messageChunkBase64: Data(chunk).base64EncodedString()),
                            clientId: envelope.clientId,
                            streamId: envelope.streamId,
                            seqId: envelope.seqId)
                    }
                }
                if chunkSize == 1 { return [] }
                let nextSegmentCount = segmentCount + 1
                let nextChunkSize = max(
                    1,
                    (messageSizeBytes + nextSegmentCount - 1) / nextSegmentCount)
                segmentCount = nextChunkSize == chunkSize
                    ? messageSizeBytes
                    : nextSegmentCount
            }
        }

        private static func serializedChunkLength(
            envelope: RemoteControlServerEnvelope,
            segmentId: Int,
            segmentCount: Int,
            messageSizeBytes: Int,
            chunk: Data.SubSequence
        ) -> Int? {
            let chunkEnvelope = RemoteControlServerEnvelope(
                event: .serverMessageChunk(
                    segmentId: segmentId,
                    segmentCount: segmentCount,
                    messageSizeBytes: messageSizeBytes,
                    messageChunkBase64: Data(chunk).base64EncodedString()),
                clientId: envelope.clientId,
                streamId: envelope.streamId,
                seqId: envelope.seqId)
            return try? JSONEncoder().encode(chunkEnvelope).count
        }
    }

    private struct RemoteControlClientSegmentAssembly {
        var streamId: String
        var seqId: UInt64
        var segmentCount: Int
        var messageSizeBytes: Int
        var raw: Data = Data()
        var nextSegmentId: Int = 0
        var lastChunkSeenAt: Date = Date()
    }

    private struct RemoteControlClientSegmentReassembler {
        private var assemblies: [String: RemoteControlClientSegmentAssembly] = [:]

        mutating func observe(
            _ envelope: RemoteControlClientEnvelope
        ) -> RemoteControlClientEnvelope? {
            guard case .clientMessageChunk(
                let segmentId,
                let segmentCount,
                let messageSizeBytes,
                let messageChunkBase64) = envelope.event else {
                return envelope
            }
            guard let seqId = envelope.seqId,
                  let streamId = envelope.streamId,
                  !streamId.isEmpty else {
                return nil
            }
            if shouldIgnoreChunk(clientId: envelope.clientId,
                                 streamId: streamId,
                                 seqId: seqId,
                                 segmentId: segmentId) {
                return nil
            }
            guard segmentCount > 0,
                  segmentCount <= RequestRouter.remoteControlSegmentCountMax,
                  segmentId >= 0,
                  segmentId < segmentCount,
                  messageSizeBytes > 0,
                  messageSizeBytes <= RequestRouter.remoteControlReassembledMaxBytes,
                  !messageChunkBase64.isEmpty,
                  let decoded = Data(base64Encoded: messageChunkBase64) else {
                removeAssembly(clientId: envelope.clientId, streamId: streamId)
                return nil
            }

            let now = Date()
            if let assembly = assemblies[envelope.clientId] {
                if assembly.streamId != streamId {
                    assemblies[envelope.clientId] = RemoteControlClientSegmentAssembly(
                        streamId: streamId,
                        seqId: seqId,
                        segmentCount: segmentCount,
                        messageSizeBytes: messageSizeBytes,
                        lastChunkSeenAt: now)
                }
            } else {
                evictAssembliesIfFull()
                assemblies[envelope.clientId] = RemoteControlClientSegmentAssembly(
                    streamId: streamId,
                    seqId: seqId,
                    segmentCount: segmentCount,
                    messageSizeBytes: messageSizeBytes,
                    lastChunkSeenAt: now)
            }

            guard var assembly = assemblies[envelope.clientId] else { return nil }
            if seqId < assembly.seqId {
                return nil
            }
            guard seqId == assembly.seqId,
                  segmentCount == assembly.segmentCount,
                  messageSizeBytes == assembly.messageSizeBytes else {
                removeAssembly(clientId: envelope.clientId, streamId: streamId)
                return nil
            }
            if segmentId < assembly.nextSegmentId {
                assemblies[envelope.clientId] = assembly
                return nil
            }
            guard segmentId == assembly.nextSegmentId else {
                removeAssembly(clientId: envelope.clientId, streamId: streamId)
                return nil
            }
            guard assembly.raw.count + decoded.count <= messageSizeBytes else {
                removeAssembly(clientId: envelope.clientId, streamId: streamId)
                return nil
            }
            assembly.raw.append(decoded)
            assembly.nextSegmentId += 1
            assembly.lastChunkSeenAt = now
            if assembly.nextSegmentId < segmentCount {
                assemblies[envelope.clientId] = assembly
                return nil
            }
            defer { removeAssembly(clientId: envelope.clientId, streamId: streamId) }
            guard assembly.raw.count == messageSizeBytes,
                  let message = try? JSONDecoder().decode(
                    JSONRPCMessage.self, from: assembly.raw) else {
                return nil
            }
            return RemoteControlClientEnvelope(
                event: .clientMessage(message),
                clientId: envelope.clientId,
                streamId: envelope.streamId,
                seqId: envelope.seqId,
                cursor: envelope.cursor)
        }

        mutating func invalidateStream(clientId: String, streamId: String) {
            removeAssembly(clientId: clientId, streamId: streamId)
        }

        mutating func invalidateClient(_ clientId: String) {
            assemblies.removeValue(forKey: clientId)
        }

        func shouldIgnoreChunk(clientId: String, streamId: String,
                               seqId: UInt64, segmentId: Int) -> Bool {
            guard let assembly = assemblies[clientId],
                  assembly.streamId == streamId else {
                return false
            }
            return seqId < assembly.seqId
                || (seqId == assembly.seqId && segmentId < assembly.nextSegmentId)
        }

        private mutating func removeAssembly(clientId: String, streamId: String) {
            if assemblies[clientId]?.streamId == streamId {
                assemblies.removeValue(forKey: clientId)
            }
        }

        private mutating func evictAssembliesIfFull() {
            while assemblies.count >= RequestRouter.remoteControlSegmentAssemblyMaxCount,
                  let oldest = assemblies.min(by: {
                      $0.value.lastChunkSeenAt < $1.value.lastChunkSeenAt
                  })?.key {
                assemblies.removeValue(forKey: oldest)
            }
        }
    }

    private final class RemoteControlVirtualConnection: ClientConnection, @unchecked Sendable {
        let clientId: String
        let streamId: String
        private let lock = NSLock()
        private var websocket: RemoteControlWebSocketConnection
        private let outbound = RemoteControlOutboundState()

        init(clientId: String, streamId: String,
             websocket: RemoteControlWebSocketConnection) {
            self.clientId = clientId
            self.streamId = streamId
            self.websocket = websocket
        }

        func send(_ message: JSONRPCMessage) async {
            await sendEvent(.serverMessage(message))
        }

        func sendPong(status: String) async {
            await sendEvent(.pong(status: status))
        }

        func ack(seqId: UInt64, segmentId: Int?) {
            outbound.ack(seqId: seqId, segmentId: segmentId)
        }

        func bufferedEnvelopes() -> [RemoteControlServerEnvelope] {
            outbound.bufferedEnvelopes()
        }

        func updateWebSocket(_ websocket: RemoteControlWebSocketConnection) {
            lock.lock()
            defer { lock.unlock() }
            self.websocket = websocket
        }

        func replayBufferedEnvelopes() async {
            let websocket = currentWebSocket()
            for envelope in outbound.bufferedEnvelopes() {
                try? await websocket.sendEnvelope(envelope)
            }
        }

        private func sendEvent(_ event: RemoteControlServerEvent) async {
            let websocket = currentWebSocket()
            for envelope in outbound.makeEnvelopes(
                event: event,
                clientId: clientId,
                streamId: streamId) {
                try? await websocket.sendEnvelope(envelope)
            }
        }

        private func currentWebSocket() -> RemoteControlWebSocketConnection {
            lock.lock()
            defer { lock.unlock() }
            return websocket
        }

        func incoming() -> AsyncStream<JSONRPCMessage> {
            AsyncStream { continuation in continuation.finish() }
        }
    }
    private struct CommandExecSessionKey: Hashable {
        var connection: ObjectIdentifier
        var processId: String
    }
    private final class CommandExecProcess: @unchecked Sendable {
        let process: Process
        let stdin: FileHandle?
        let ptyMaster: FileHandle?
        let stdinCloseable: Bool
        let outputTasks: [Task<Void, Never>]
        init(process: Process, stdin: FileHandle?, ptyMaster: FileHandle? = nil,
             stdinCloseable: Bool = true,
             outputTasks: [Task<Void, Never>] = []) {
            self.process = process
            self.stdin = stdin
            self.ptyMaster = ptyMaster
            self.stdinCloseable = stdinCloseable
            self.outputTasks = outputTasks
        }
    }
    private var commandExecSessions: [CommandExecSessionKey: CommandExecProcess] = [:]
    private struct ProcessSessionKey: Hashable {
        var connection: ObjectIdentifier
        var processHandle: String
    }
    private final class ProcessSession: @unchecked Sendable {
        let process: Process
        let stdin: FileHandle?
        let ptyMaster: FileHandle?
        let stdinCloseable: Bool
        let outputTasks: [Task<Void, Never>]
        /// Per-stream output buffer + cap tracker. In streaming mode the bytes
        /// are forwarded via `process/outputDelta` and not retained; in
        /// buffered mode they are captured and emitted on `process/exited`.
        let output: CommandExecOutputBuffer
        let streamOutput: Bool
        init(process: Process, stdin: FileHandle?, ptyMaster: FileHandle? = nil,
             stdinCloseable: Bool = true,
             outputTasks: [Task<Void, Never>] = [],
             output: CommandExecOutputBuffer,
             streamOutput: Bool) {
            self.process = process
            self.stdin = stdin
            self.ptyMaster = ptyMaster
            self.stdinCloseable = stdinCloseable
            self.outputTasks = outputTasks
            self.output = output
            self.streamOutput = streamOutput
        }
    }
    private var processSessions: [ProcessSessionKey: ProcessSession] = [:]

    public init(supervisor: SessionSupervisor, store: ThreadStore,
                codexHome: String, auth: AuthManager? = nil,
                config: Config? = nil,
                requirementsLoader: ConfigRequirementsLoader = ConfigRequirementsLoader(),
                accountRateLimitsFetcher: AccountRateLimitsFetcher? = nil,
                accountNudgeEmailSender: AccountNudgeEmailSender? = nil,
                remoteControlEnroller: RemoteControlEnroller? = nil,
                remoteControlWebSocketConnector: RemoteControlWebSocketConnector? = nil,
                memoryResetHandler: (@Sendable () async -> Void)? = nil,
                wikiQuery: WikiQueryHandle? = nil,
                realtimeBackendFactory: RealtimeBackendFactory? = nil,
                allowsOwnerOnlyRPC: Bool = true) {
        self.supervisor = supervisor
        self.store = store
        self.allowsOwnerOnlyRPC = allowsOwnerOnlyRPC
        self.codexHome = codexHome
        self.auth = auth
        self.config = config
        self.requirementsLoader = requirementsLoader
        self.accountRateLimitsFetcher = accountRateLimitsFetcher ?? Self.fetchAccountRateLimits
        self.accountNudgeEmailSender = accountNudgeEmailSender ?? Self.sendAddCreditsNudgeEmail
        self.remoteControlEnroller = remoteControlEnroller ?? Self.enrollRemoteControl
        self.remoteControlWebSocketConnector =
            remoteControlWebSocketConnector ?? Self.connectRemoteControlWebSocket
        self.memoryResetHandler = memoryResetHandler
        self.wikiQuery = wikiQuery
        self.realtimeBackendFactory = realtimeBackendFactory
    }

    public func handle(_ message: JSONRPCMessage, _ conn: any ClientConnection) async {
        switch message {
        case .notification(let n):
            if ClientNotification.parse(n) == .initialized { /* handshake ack */ }
        case .request(let raw):
            await handleRequest(raw, conn)
        case .response(let r):
            if resolveDirectServerResponse(r.id.description, result: r.result) { return }
            await supervisor.deliverServerResponse(r.id.description, result: r.result)
        case .error(let e):
            if resolveDirectServerResponse(e.id.description, result: nil) { return }
            await supervisor.deliverServerResponse(e.id.description,
                                                   result: nil,
                                                   failed: true)
        }
    }

    /// ACCEPTED DIVERGENCE — per-connection RPC gate (app-server-registry/finding-2).
    /// Upstream `app-server` defines `ConnectionRpcGate`
    /// (app-server/src/connection_rpc_gate.rs:11-48) whose `shutdown()` flips
    /// `accepting=false`, closes the TaskTracker, and awaits in-flight handlers;
    /// message_processor.rs:706 calls `session_state.rpc_gate.shutdown()` here in
    /// `connection_closed` so queued-but-not-started handlers are dropped while
    /// started ones finish before teardown completes.
    ///
    /// This Swift port INTENTIONALLY SIMPLIFIES that gate. There is no
    /// `accepting` flag checked at the top of `dispatch`, nor a drain/await of
    /// in-flight request `Task`s. Instead we rely on:
    ///   1. the actor finishing its current continuation naturally — a handler
    ///      that already started completes (no partial execution); and
    ///   2. `conn.send` to a closed connection being a no-op — a late
    ///      response/notification produces no wire-visible garbage to any client.
    /// Per-feature cleanup below (file/skills watchers, login flows, fuzzy /
    /// command-exec / process sessions) covers the resources that matter. The
    /// upstream gate is defensive hardening; this approach is sufficient for the
    /// single-user-client scenarios this port targets. Strict parity would add a
    /// per-connection accepting-flag checked at the top of `dispatch` plus a
    /// drain/await of in-flight request Tasks here, mirroring `ConnectionRpcGate`.
    public func connectionClosed(_ conn: any ClientConnection) async {
        await fileWatchManager.connectionClosed(conn: conn)
        await skillsChangeWatchManager.connectionClosed(conn: conn)
        let connection = ObjectIdentifier(conn as AnyObject)
        if let loginId = pendingLoginIds.removeValue(forKey: connection) {
            if let pending = pendingDeviceLogins.removeValue(forKey: loginId) {
                pending.task.cancel()
            }
            if let pending = pendingBrowserLogins.removeValue(forKey: loginId) {
                pending.timeoutTask.cancel()
                pending.server.stop()
            }
        }
        await cancelFuzzySearchSessions(connection: connection)
        await terminateCommandExecSessions(connection: connection)
        await terminateProcessSessions(connection: connection)
        // Close any live realtime voice sessions so the upstream Realtime API
        // WebSocket is not leaked when a tab disconnects without `stop`. Each
        // per-connection router owns its own sessions.
        let liveSessions = liveRealtimeSessions
        liveRealtimeSessions.removeAll()
        for (_, session) in liveSessions {
            await session.stop(reason: "connection_closed")
        }
    }

    // Internal (not private) so the wiki dispatch carved into
    // RequestRouter+Wiki.swift can reply through the same path.
    func reply(_ conn: any ClientConnection, _ id: RequestId, _ result: JSONValue) async {
        await conn.send(.response(JSONRPCResponse(id: id, result: result)))
    }

    // The wiki/* dispatch arms + their helpers (replyWiki, clampWiki*,
    // WikiNotFound) live in RequestRouter+Wiki.swift to keep the growing wiki
    // RPC surface out of this ~10k-line file. See dispatchWiki(_:_:).
    private func reply<T: Encodable>(_ conn: any ClientConnection, _ id: RequestId, _ v: T) async {
        await reply(conn, id, (try? JSONBridge.value(v)) ?? .object([:]))
    }

    private static func emptyRateLimitSnapshot() -> JSONValue {
        .object([
            "limitId": .null,
            "limitName": .null,
            "primary": .null,
            "secondary": .null,
            "credits": .null,
            "planType": .null,
            "rateLimitReachedType": .null,
        ])
    }

    private static func chatGPTBaseURL(codexHome: String) -> String {
        let loaded = ConfigLoader(codexHome: codexHome).load()
        return loaded.string("chatgpt_base_url")
            ?? loaded.string("chatgptBaseUrl")
            ?? "https://chatgpt.com/backend-api"
    }

    private static func fetchAccountRateLimits(tokens: AuthTokens,
                                               baseURL: String) async throws -> JSONValue {
        var normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if (normalizedBase == "https://chatgpt.com"
            || normalizedBase == "https://chat.openai.com")
            && !normalizedBase.contains("/backend-api") {
            normalizedBase += "/backend-api"
        }
        guard var components = URLComponents(string: normalizedBase) else {
            throw SimpleError("invalid ChatGPT base URL")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = normalizedBase.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        components.path = (basePath.isEmpty ? "" : "/" + basePath) + suffix
        guard let url = components.url else { throw SimpleError("invalid rate-limit URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = tokens.accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimpleError("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SimpleError("HTTP \(http.statusCode)")
        }
        let any = try JSONSerialization.jsonObject(with: data)
        guard let body = jsonAnyToValue(any).objectValue else {
            throw SimpleError("malformed rate-limit response")
        }
        return rateLimitResponse(from: body)
    }

    /// Invalid-cursor / cursor-out-of-range conditions for `permissionProfile/list`,
    /// mapped to `invalid_request` to mirror upstream (catalog_processor.rs:472-481).
    struct PermissionProfileListError: Error { let message: String }

    /// Build the `permissionProfile/list` response: three built-in profiles
    /// (`:read-only`, `:workspace`, `:danger-full-access`) followed by configured
    /// `[permissions.<id>]` profiles sorted by id, then offset/limit pagination.
    /// Faithful port of `permission_profile_list_response`.
    static func permissionProfileListResponse(
        params: PermissionProfileListParams, codexHome: String
    ) throws -> PermissionProfileListResponse {
        let effectiveConfig = ConfigLoader(codexHome: codexHome,
                                           cwdOverride: params.cwd).load()
        if let loadError = effectiveConfig.loadError {
            throw SimpleError(loadError)
        }
        var profiles: [PermissionProfileSummary] = BuiltInPermissionProfile.ordered
            .map { PermissionProfileSummary(id: $0, description: nil) }
        let configured = (effectiveConfig.value("permissions")?.objectValue ?? [:])
            .map { (id, value) in
                PermissionProfileSummary(
                    id: id,
                    description: value.objectValue?["description"]?.stringValue)
            }
            .sorted { $0.id < $1.id }
        profiles.append(contentsOf: configured)

        let total = profiles.count
        let limit = Int(params.limit ?? UInt32(total))
        let effectiveLimit = max(1, min(limit, total))
        let start: Int
        if let cursor = params.cursor {
            guard let parsed = Int(cursor), parsed >= 0 else {
                throw PermissionProfileListError(message: "invalid cursor: \(cursor)")
            }
            start = parsed
        } else {
            start = 0
        }
        if start > total {
            throw PermissionProfileListError(
                message: "cursor \(start) exceeds total permission profiles \(total)")
        }
        let end = min(start + effectiveLimit, total)
        let data = Array(profiles[start..<end])
        let nextCursor = end < total ? String(end) : nil
        return PermissionProfileListResponse(data: data, nextCursor: nextCursor)
    }

    /// Fetch the backend token-usage profile and project it onto
    /// `GetAccountTokenUsageResponse`. Mirrors `account_token_usage_response`
    /// (`/wham/profiles/me` on ChatGPT, `/api/codex/profiles/me` on codex-api).
    private static func fetchAccountTokenUsage(
        tokens: AuthTokens, baseURL: String
    ) async throws -> GetAccountTokenUsageResponse {
        var normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if (normalizedBase == "https://chatgpt.com"
            || normalizedBase == "https://chat.openai.com")
            && !normalizedBase.contains("/backend-api") {
            normalizedBase += "/backend-api"
        }
        guard var components = URLComponents(string: normalizedBase) else {
            throw SimpleError("invalid ChatGPT base URL")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = normalizedBase.contains("/backend-api")
            ? "/wham/profiles/me" : "/api/codex/profiles/me"
        components.path = (basePath.isEmpty ? "" : "/" + basePath) + suffix
        guard let url = components.url else { throw SimpleError("invalid token-usage URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = tokens.accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimpleError("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SimpleError("HTTP \(http.statusCode)")
        }
        return try projectTokenUsageProfile(data)
    }

    /// Project the backend `TokenUsageProfile` JSON (`{ stats: {...} }`,
    /// snake_case) onto the wire response. Pure + total so it is unit-testable
    /// without a network round-trip.
    static func projectTokenUsageProfile(_ data: Data) throws -> GetAccountTokenUsageResponse {
        let any = try JSONSerialization.jsonObject(with: data)
        let stats = (jsonAnyToValue(any).objectValue?["stats"])?.objectValue ?? [:]
        let buckets = stats["daily_usage_buckets"]?.arrayValue?.compactMap { v -> AccountTokenUsageDailyBucket? in
            guard let o = v.objectValue,
                  let startDate = o["start_date"]?.stringValue,
                  let tokens = o["tokens"]?.intValue else { return nil }
            return AccountTokenUsageDailyBucket(startDate: startDate, tokens: tokens)
        }
        return GetAccountTokenUsageResponse(
            summary: AccountTokenUsageSummary(
                lifetimeTokens: stats["lifetime_tokens"]?.intValue,
                peakDailyTokens: stats["peak_daily_tokens"]?.intValue,
                longestRunningTurnSec: stats["longest_running_turn_sec"]?.intValue,
                currentStreakDays: stats["current_streak_days"]?.intValue,
                longestStreakDays: stats["longest_streak_days"]?.intValue),
            dailyUsageBuckets: buckets)
    }

    private static func sendAddCreditsNudgeEmail(tokens: AuthTokens,
                                                 baseURL: String,
                                                 creditType: String) async throws -> String {
        var normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if (normalizedBase == "https://chatgpt.com"
            || normalizedBase == "https://chat.openai.com")
            && !normalizedBase.contains("/backend-api") {
            normalizedBase += "/backend-api"
        }
        guard var components = URLComponents(string: normalizedBase) else {
            throw SimpleError("invalid ChatGPT base URL")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = normalizedBase.contains("/backend-api")
            ? "/wham/accounts/send_add_credits_nudge_email"
            : "/api/codex/accounts/send_add_credits_nudge_email"
        components.path = (basePath.isEmpty ? "" : "/" + basePath) + suffix
        guard let url = components.url else { throw SimpleError("invalid nudge URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountId = tokens.accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["credit_type": creditType])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimpleError("missing HTTP response")
        }
        if http.statusCode == 429 {
            throw AccountNudgeEmailHTTPStatusError(statusCode: 429)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AccountNudgeEmailHTTPStatusError(statusCode: http.statusCode)
        }
        return "sent"
    }

    private static func enrollRemoteControl(tokens: AuthTokens,
                                            baseURL: String,
                                            installationId: String,
                                            serverName: String) async throws -> RemoteControlEnrollment {
        let target = try normalizedRemoteControlTarget(baseURL)
        guard let url = URL(string: target.enrollURL) else {
            throw SimpleError("invalid remote-control enrollment URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(installationId, forHTTPHeaderField: "x-codex-installation-id")
        if let accountId = tokens.accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": serverName,
            "os": currentOperatingSystemName(),
            "arch": currentArchitectureName(),
            "app_server_version": "codexkit",
            "installation_id": installationId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimpleError("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = Self.remoteControlResponsePreview(data)
            let suffix = preview == "<empty>" ? "" : ": \(preview)"
            throw SimpleError("HTTP \(http.statusCode)\(suffix)")
        }
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SimpleError(
                "failed to parse remote-control enrollment response: \(Self.remoteControlResponsePreview(data))")
        }
        guard let object = any as? [String: Any],
              let serverId = object["server_id"] as? String,
              !serverId.isEmpty,
              let environmentId = object["environment_id"] as? String,
              !environmentId.isEmpty else {
            throw SimpleError(
                "malformed remote-control enrollment response: \(Self.remoteControlResponsePreview(data))")
        }
        return RemoteControlEnrollment(serverId: serverId, environmentId: environmentId)
    }

    static func remoteControlWebSocketURLRequest(
        _ request: RemoteControlWebSocketRequest
    ) throws -> URLRequest {
        guard let url = URL(string: request.websocketURL) else {
            throw SimpleError("invalid remote-control websocket URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(request.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = request.accountId {
            urlRequest.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        urlRequest.setValue(request.installationId, forHTTPHeaderField: "x-codex-installation-id")
        urlRequest.setValue(request.serverId, forHTTPHeaderField: "x-codex-server-id")
        urlRequest.setValue(
            Data(request.serverName.utf8).base64EncodedString(),
            forHTTPHeaderField: "x-codex-name")
        urlRequest.setValue("3", forHTTPHeaderField: "x-codex-protocol-version")
        return urlRequest
    }

    private static func connectRemoteControlWebSocket(
        _ request: RemoteControlWebSocketRequest
    ) async throws -> RemoteControlWebSocketConnection {
        let urlRequest = try remoteControlWebSocketURLRequest(request)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: urlRequest)
        let (incoming, continuation) = AsyncStream<RemoteControlClientEnvelope>.makeStream()
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw error
        }
        let receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let envelope = try? JSONDecoder().decode(
                            RemoteControlClientEnvelope.self, from: data) {
                            continuation.yield(envelope)
                        }
                    case .data(let data):
                        if let envelope = try? JSONDecoder().decode(
                            RemoteControlClientEnvelope.self, from: data) {
                            continuation.yield(envelope)
                        }
                    @unknown default:
                        continue
                    }
                } catch {
                    continuation.finish()
                    break
                }
            }
        }
        return RemoteControlWebSocketConnection(
            incoming: incoming,
            sendEnvelope: { envelope in
                let data = try JSONEncoder().encode(envelope)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw SimpleError("failed to encode remote-control server envelope")
                }
                try await task.send(.string(text))
            },
            ping: {
                try await withCheckedThrowingContinuation {
                    (cont: CheckedContinuation<Void, any Error>) in
                    task.sendPing { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }
            },
            close: {
            receiveTask.cancel()
            continuation.finish()
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        })
    }

    static func normalizedRemoteControlTarget(_ raw: String) throws -> RemoteControlTarget {
        let parseError = "invalid remote control URL `\(raw)`"
        let schemeError = "invalid remote control URL `\(raw)`; expected HTTPS URL for chatgpt.com or chatgpt-staging.com, or HTTP/HTTPS URL for localhost"
        guard let base = URL(string: raw),
              let components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw SimpleError(parseError)
        }
        let isChatGPTHost = host == "chatgpt.com"
            || host == "chatgpt-staging.com"
            || host.hasSuffix(".chatgpt.com")
            || host.hasSuffix(".chatgpt-staging.com")
        let isLocalhost = host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
        let websocketScheme: String
        switch scheme {
        case "https" where isChatGPTHost || isLocalhost:
            websocketScheme = "wss"
        case "http" where isLocalhost:
            websocketScheme = "ws"
        default:
            throw SimpleError(schemeError)
        }

        let enrollURL = Self.remoteControlURL(
            base: base,
            scheme: scheme,
            pathComponents: ["wham", "remote", "control", "server", "enroll"])
        let websocketURL = Self.remoteControlURL(
            base: base,
            scheme: websocketScheme,
            pathComponents: ["wham", "remote", "control", "server"])
        return RemoteControlTarget(
            websocketURL: websocketURL.absoluteString,
            enrollURL: enrollURL.absoluteString)
    }

    private static func remoteControlURL(base: URL,
                                         scheme: String,
                                         pathComponents: [String]) -> URL {
        var url = base
        for component in pathComponents {
            url.appendPathComponent(component, isDirectory: false)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private static func remoteControlResponsePreview(_ data: Data) -> String {
        let maxBytes = 4096
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "<empty>" }
        guard let limited = text.data(using: .utf8), limited.count > maxBytes else {
            return text
        }
        var end = text.startIndex
        var bytes = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let width = String(text[end..<next]).utf8.count
            if bytes + width > maxBytes { break }
            bytes += width
            end = next
        }
        return String(text[..<end]) + "..."
    }

    private static func currentOperatingSystemName() -> String {
        #if os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "windows"
        #else
        return "unknown"
        #endif
    }

    private static func currentArchitectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(arm)
        return "arm"
        #elseif arch(i386)
        return "x86"
        #else
        return "unknown"
        #endif
    }

    /// Test hook exposing the backend-usage → wire-snapshot mapping
    /// (credits, plan type, rate-limit windows) without spinning up an HTTP
    /// server. Mirrors the production parse performed by `fetchAccountRateLimits`.
    static func _rateLimitResponseForTesting(from body: [String: JSONValue]) -> JSONValue {
        rateLimitResponse(from: body)
    }

    private static func rateLimitResponse(from body: [String: JSONValue]) -> JSONValue {
        let planType = body["plan_type"]?.stringValue
        // Only the primary ("codex") snapshot carries credits, sourced from the
        // backend usage payload's top-level `credits` object; additional rate
        // limits pass no credits (backend-client/src/client.rs:455-475).
        let primary = rateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            rateLimit: body["rate_limit"],
            credits: body["credits"],
            planType: planType,
            reachedType: body["rate_limit_reached_type"])
        var byLimit: [String: JSONValue] = ["codex": primary]
        for extra in body["additional_rate_limits"]?.arrayValue ?? [] {
            guard let object = extra.objectValue else { continue }
            let limitId = object["metered_feature"]?.stringValue
                ?? object["limit_id"]?.stringValue
                ?? object["limit_name"]?.stringValue
                ?? "codex_other"
            byLimit[limitId] = rateLimitSnapshot(
                limitId: limitId,
                limitName: object["limit_name"]?.stringValue,
                rateLimit: object["rate_limit"],
                credits: nil,
                planType: planType,
                reachedType: object["rate_limit_reached_type"])
        }
        return .object([
            "rateLimits": primary,
            "rateLimitsByLimitId": .object(byLimit),
        ])
    }

    private static func rateLimitSnapshot(limitId: String,
                                          limitName: String?,
                                          rateLimit: JSONValue?,
                                          credits: JSONValue?,
                                          planType: String?,
                                          reachedType: JSONValue?) -> JSONValue {
        let rate = rateLimit?.objectValue ?? [:]
        return .object([
            "limitId": .string(limitId),
            "limitName": limitName.map(JSONValue.string) ?? .null,
            "primary": rateLimitWindow(rate["primary_window"]),
            "secondary": rateLimitWindow(rate["secondary_window"]),
            "credits": creditsSnapshot(credits),
            // Canonicalize the backend `plan_type` through the AccountPlanType
            // enum before emitting, matching upstream `map_plan_type`
            // (backend-client/src/client.rs:567-589): education->edu and
            // guest/free_workspace/quorum/k12/unknown/unrecognized -> "unknown".
            "planType": planType.map { AccountPlanType.normalize(rawValue: $0).wireValue }
                .map(JSONValue.string) ?? .null,
            "rateLimitReachedType": normalizedRateLimitReachedType(reachedType),
        ])
    }

    /// Maps the backend usage payload's `credits` object (snake_case
    /// `has_credits`/`unlimited`/`balance`) to the camelCase CreditsSnapshot
    /// shape, falling back to null when the object is absent. Mirrors
    /// upstream `Client::map_credits` (backend-client/src/client.rs:557-564)
    /// and CreditsSnapshot{hasCredits,unlimited,balance}
    /// (app-server-protocol/src/protocol/v2/account.rs:355-362).
    private static func creditsSnapshot(_ value: JSONValue?) -> JSONValue {
        guard let object = value?.objectValue else { return .null }
        return .object([
            "hasCredits": .bool(object["has_credits"]?.boolValue ?? false),
            "unlimited": .bool(object["unlimited"]?.boolValue ?? false),
            "balance": object["balance"].flatMap { $0.isNull ? nil : $0 } ?? .null,
        ])
    }

    /// Mirrors Rust `http::HeaderValue::from_str` validity: a string is a valid
    /// HTTP header value iff every byte is visible ASCII (`0x21..=0x7E`), a
    /// space (`0x20`), or a horizontal tab (`0x09`). All other control bytes
    /// (`0x00..=0x1F` except tab), DEL (`0x7F`), and non-ASCII (`>= 0x80`) bytes
    /// are rejected. Empty strings are accepted (an empty HeaderValue is Ok).
    /// Used by `initialize` to validate `clientInfo.name`
    /// (initialize_processor.rs:88-92).
    static func isValidHTTPHeaderValue(_ s: String) -> Bool {
        for byte in s.utf8 {
            let ok = (byte >= 0x20 && byte <= 0x7E) || byte == 0x09
            if !ok { return false }
        }
        return true
    }

    static func rateLimitWindow(_ value: JSONValue?) -> JSONValue {
        guard let object = value?.objectValue else { return .null }
        let seconds = object["limit_window_seconds"]?.intValue
        // Upstream `window_minutes_from_seconds` (backend-client/src/client.rs:592-598)
        // returns `None` for `seconds <= 0` and otherwise CEILING-divides to
        // minutes via `(seconds + 59) / 60` (e.g. 90s -> 2 min). Mirror exactly:
        // floor division (`$0 / 60`) under-reports any non-multiple-of-60 window.
        let windowMins: JSONValue = seconds.flatMap { secs in
            secs > 0 ? .int((secs + 59) / 60) : nil
        } ?? .null
        // Upstream `RateLimitWindow.used_percent` is an `i32`; `RateLimitWindow::from`
        // (account.rs:347) always `.round()`s the backend float. Mirror that here so
        // the synchronous read response agrees with the updated-notification path
        // (ModelProvider.asNotificationJSON line 407) and never leaks a JSON float.
        func asDouble(_ v: JSONValue?) -> Double? {
            switch v {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }
        let usedPercent: JSONValue = asDouble(object["used_percent"])
            .map { .int(Int64($0.rounded())) } ?? .null
        return .object([
            "usedPercent": usedPercent,
            "windowDurationMins": windowMins,
            "resetsAt": object["reset_at"] ?? .null,
        ])
    }

    private static func normalizedRateLimitReachedType(_ value: JSONValue?) -> JSONValue {
        guard let type = value?["type"]?.stringValue else { return .null }
        // Upstream `map_rate_limit_reached_type` (backend-client/src/client.rs:504-525)
        // maps the five known backend kinds 1:1 and collapses
        // BackendRateLimitReachedKind::Unknown -> None (wire null). The backend
        // kind uses `#[serde(rename="unknown", other)]`, so any unrecognized
        // value also deserializes to Unknown and surfaces as null.
        switch type {
        case "rate_limit_reached",
             "workspace_owner_credits_depleted",
             "workspace_member_credits_depleted",
             "workspace_owner_usage_limit_reached",
             "workspace_member_usage_limit_reached":
            return .string(type)
        default:
            return .null
        }
    }

    private static func jwtStringClaim(_ token: String?, keys: [String]) -> String? {
        guard let object = decodeJWTPayload(token) else { return nil }
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    /// Base64URL-decodes the payload segment of a JWT and parses it as a JSON
    /// object. Returns nil when the token is malformed.
    private static func decodeJWTPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Resolves the ChatGPT plan type from an id_token. Upstream
    /// (`codex_login::token_data::parse_chatgpt_jwt_claims` /
    /// `AuthClaims::chatgpt_plan_type`) reads the plan exclusively from the
    /// nested `https://api.openai.com/auth` claim object, then canonicalizes it
    /// via the two-stage `PlanType::from_raw_value` -> account `PlanType`
    /// mapping (`AccountPlanType.normalize`): aliases like `hc` -> `enterprise`,
    /// `education` -> `edu`, and any unrecognized value -> `unknown` (never
    /// leaked verbatim). Real ChatGPT id_tokens carry the plan only at this
    /// nested path; a legacy flat-key fallback is retained for resilience.
    /// Returns `nil` only when the claim is absent entirely; callers default an
    /// absent plan to `"unknown"`.
    static func chatgptPlanType(_ token: String?) -> String? {
        guard let object = decodeJWTPayload(token) else { return nil }
        if let auth = object["https://api.openai.com/auth"] as? [String: Any],
           let plan = auth["chatgpt_plan_type"] as? String {
            return AccountPlanType.normalize(rawValue: plan).wireValue
        }
        // Legacy flat-key fallback for resilience.
        let flat = object["https://api.openai.com/plan_type"] as? String
            ?? object["plan_type"] as? String
            ?? object["planType"] as? String
        return flat.map { AccountPlanType.normalize(rawValue: $0).wireValue }
    }

    private func finishDeviceCodeLogin(loginId: String, auth: AuthManager,
                                       challenge: DeviceCodeChallenge,
                                       conn: any ClientConnection) async {
        let result = await auth.deviceCodeComplete(challenge)
        guard pendingDeviceLogins.removeValue(forKey: loginId) != nil else {
            return
        }
        let connection = ObjectIdentifier(conn as AnyObject)
        if pendingLoginIds[connection] == loginId {
            pendingLoginIds.removeValue(forKey: connection)
        }
        switch result {
        case .success:
            let tokens = await auth.storedTokens()
            let planType = Self.chatgptPlanType(tokens?.idToken)
            await conn.send(ServerNotification.accountLoginCompleted(
                loginId: loginId, success: true, error: nil).toMessage())
            await conn.send(ServerNotification.accountUpdated(
                authMode: "chatgpt", planType: planType).toMessage())
        case .failure(let error):
            await conn.send(ServerNotification.accountLoginCompleted(
                loginId: loginId, success: false, error: "\(error)").toMessage())
        }
    }

    private func finishBrowserLogin(loginId: String, auth: AuthManager,
                                    values: [String: String],
                                    conn: any ClientConnection) async
    -> ChatGPTLoginCallbackResponse {
        guard let pending = pendingBrowserLogins.removeValue(forKey: loginId) else {
            return .failure("Login is no longer pending.")
        }
        pending.timeoutTask.cancel()
        let streamlined = pending.server.codexStreamlinedLogin
        pending.server.stop()
        let connection = ObjectIdentifier(conn as AnyObject)
        if pendingLoginIds[connection] == loginId {
            pendingLoginIds.removeValue(forKey: connection)
        }

        let result: Result<AccountInfo, AuthError>
        if let error = values["error"], !error.isEmpty {
            result = .failure(.server(values["error_description"] ?? "Sign-in failed: \(error)"))
        } else if let code = values["code"], !code.isEmpty,
                  let state = values["state"], !state.isEmpty {
            result = await auth.loginFinish(code: code, state: state)
        } else {
            result = .failure(.malformed("missing authorization code"))
        }

        switch result {
        case .success:
            let tokens = await auth.storedTokens()
            let planType = Self.chatgptPlanType(tokens?.idToken)
            await conn.send(ServerNotification.accountLoginCompleted(
                loginId: loginId, success: true, error: nil).toMessage())
            await conn.send(ServerNotification.accountUpdated(
                authMode: "chatgpt", planType: planType).toMessage())
            return .success(streamlined: streamlined)
        case .failure(let error):
            await conn.send(ServerNotification.accountLoginCompleted(
                loginId: loginId, success: false,
                error: Self.browserLoginCompletionError(error)).toMessage())
            return .failure("\(error)")
        }
    }

    /// Builds the `account/login/completed` notification error text for a
    /// failed browser login. Upstream's browser background task maps the
    /// login-server result `Ok(Err(err))` to `Some(format!("Login server
    /// error: {err}"))` (account_processor.rs:397-398), so the wire error is
    /// always prefixed "Login server error: " for browser-login failures
    /// (matching the cancelled-browser-login path). Internal for testability.
    static func browserLoginCompletionError(_ error: AuthError) -> String {
        "Login server error: \(error)"
    }

    private func timeoutBrowserLogin(loginId: String, conn: any ClientConnection) async {
        guard let pending = pendingBrowserLogins.removeValue(forKey: loginId) else {
            return
        }
        pending.server.stop()
        if pendingLoginIds[pending.connection] == loginId {
            pendingLoginIds.removeValue(forKey: pending.connection)
        }
        await conn.send(ServerNotification.accountLoginCompleted(
            loginId: loginId, success: false, error: "Login timed out").toMessage())
    }

    private func handleRequest(_ raw: JSONRPCRequest, _ conn: any ClientConnection) async {
        if raw.method == "initialize" {
            if initialized {
                await conn.send(WireError.invalidRequest(id: raw.id, WireError.alreadyInitialized))
                return
            }
            let parsed: ClientRequest
            do { parsed = try ClientRequest.parse(raw) }
            catch ProtocolError.invalidParams(let m) {
                await conn.send(WireError.invalidRequest(id: raw.id, m)); return
            } catch {
                await conn.send(WireError.invalidRequest(id: raw.id, "\(error)")); return
            }
            guard case .initialize(let id, let p) = parsed else {
                await conn.send(WireError.invalidRequest(id: raw.id, "invalid initialize"))
                return
            }
            // Audit app-server-registry/finding-2: upstream validates
            // `clientInfo.name` is a valid HTTP header value BEFORE committing
            // session state (initialize_processor.rs:88-92,
            // `if HeaderValue::from_str(&name).is_err()`). A name containing
            // control chars (newlines, etc.) or non-ASCII bytes is invalid as a
            // header value and the connection must NOT become initialized.
            if !Self.isValidHTTPHeaderValue(p.clientInfo.name) {
                await conn.send(WireError.invalidRequest(
                    id: raw.id,
                    "Invalid clientInfo.name: '\(p.clientInfo.name)'. Must be a valid HTTP header value."))
                return
            }
            initialized = true
            caps = p.capabilities ?? ClientCapabilities()
            let res = InitializeResult(
                userAgent: "CodexKit/0.1 (\(p.clientInfo.name))",
                codexHome: codexHome,
                platformFamily: platformFamily(),
                platformOs: platformOs())
            await reply(conn, id, res)
            return
        }

        if !initialized {
            await conn.send(WireError.invalidRequest(id: raw.id, WireError.notInitialized))
            return
        }

        // Audit app-server-registry/finding-3 (ordering parity): upstream
        // deserializes the `ClientRequest` FIRST (message_processor.rs:536-541,
        // `Invalid request: <serde error>` on failure) and only then derives the
        // experimental rejection from the typed request via `experimental_reason()`
        // (dispatch_initialized_client_request, message_processor.rs:792-796).
        // The threadId well-formedness check likewise happens inside the typed
        // processors after deserialization. So parse before gating: a
        // malformed-params request to an experimental method (or one carrying a
        // malformed threadId) must surface the deserialization error, not the
        // experimental/threadId message. Well-formed requests are unaffected
        // (they parse, then hit the same checks with identical messages).
        let parsed: ClientRequest
        do { parsed = try ClientRequest.parse(raw) }
        catch ProtocolError.invalidParams(let m) {
            await conn.send(WireError.invalidRequest(id: raw.id, m)); return
        } catch {
            await conn.send(WireError.invalidRequest(id: raw.id, "\(error)")); return
        }

        if let desc = gate.rejectionDescriptor(
            method: raw.method, presentFields: presentFields(raw.params), caps: caps) {
            await conn.send(WireError.experimental(id: raw.id, descriptor: desc))
            return
        }

        // Audit app-server-registry/finding-3: upstream has NO generic
        // dispatch-level threadId well-formedness check; each processor parses
        // its own `threadId` AFTER the experimental gate
        // (message_processor.rs:792-796 gates first; then e.g.
        // turn_processor.rs:192 / thread_processor.rs:669 emit
        // `invalid_request("invalid thread id: {err}")`). So this generic
        // precheck must run AFTER the experimental gate above (an experimental
        // method called by a non-experimental connection with a malformed
        // threadId surfaces the capability error, not the threadId error) and
        // must match upstream's "invalid thread id: <error>" message form.
        if let tidVal = raw.params?["threadId"], let s = tidVal.stringValue,
           !ThreadId(s).isWellFormed {
            await conn.send(WireError.invalidRequest(
                id: raw.id, "invalid thread id: malformed thread id"))
            return
        }

        if await validateRemoteEnvironmentSelection(
            id: raw.id, method: raw.method, params: raw.params, conn: conn) {
            return
        }

        await dispatch(parsed, conn)
    }

    private func dispatch(_ parsed: ClientRequest, _ conn: any ClientConnection) async {
        switch parsed {
        case .initialize:
            break

        // MARK: thread lifecycle
        case .threadStart(let id, let p):
            // NOTE (audit app-server-registry/finding-4): upstream's websocket
            // `thread/start` path has no capacity overload (-32001 originates
            // ONLY from the in-process embedder's bounded mpsc queue,
            // app-server/src/in_process.rs:548,632). The port DELIBERATELY
            // diverges here: it retains thread/start admission control as a
            // DoS-safety hardening, covered by
            // AuthGatingAdversarialTests.testSessionFloodAdmissionControl.
            // Removing it would let an unauthenticated flood spawn unbounded
            // worker sessions. Kept as an accepted, test-backed divergence.
            if await supervisor.atCapacity() {
                await conn.send(WireError.overload(id: id)); return
            }
            let environment = selectedRemoteEnvironment(p.environments)
            let cwd = p.environments?.first?.cwd
                ?? p.cwd
                ?? FileManager.default.currentDirectoryPath
            let latestConfig = ConfigLoader(codexHome: codexHome).load()
            // prompts finding A/B/C: thread the AGENTS.md knobs from live config
            // into SessionConfig so the model actually sees the global
            // (~/.codex/AGENTS.override.md / AGENTS.md) instructions, honours
            // configured fallback filenames + custom root markers, and obeys the
            // configured project_doc_max_bytes budget (0 disables AGENTS.md).
            let agentsMd = Self.agentsMdConfig(latestConfig, codexHome: codexHome, cwd: cwd)
            let cfg = SessionConfig(
                threadId: ThreadId.generate(),
                cwd: cwd,
                model: p.model ?? "gpt-5.5",
                ephemeral: p.ephemeral ?? false,
                personality: p.personality,
                developerInstructions: p.developerInstructions,
                baseInstructions: p.baseInstructions,
                approvalPolicy: Self.approvalPolicy(from: p.approvalPolicy,
                                                     default: Self.approvalPolicyFallback(from: latestConfig)),
                approvalsReviewer: p.approvalsReviewer ?? "user",
                sandboxMode: Self.sandboxMode(from: p.sandbox,
                                              fallbackConfig: latestConfig),
                notify: Self.notifyArgv(from: latestConfig),
                remoteEnvironment: environment,
                agentsMdUserInstructions: agentsMd.userInstructions,
                agentsMdFilenames: agentsMd.filenames,
                agentsMdProjectRootMarkers: agentsMd.projectRootMarkers,
                agentsMdChildEnabled: agentsMd.childEnabled,
                projectDocMaxBytes: agentsMd.projectDocMaxBytes,
                reasoningEffort: latestConfig.value("model_reasoning_effort")?.stringValue,
                textVerbosity: latestConfig.value("model_verbosity")?.stringValue,
                // persistence-rollout finding 5: gate the interrupted-turn
                // history marker on `config.agents.interrupt_message` (upstream
                // `agent_interrupt_message_enabled`, default true).
                agentInterruptMessageEnabled: latestConfig.agentInterruptMessageEnabled,
                // model-client finding 1: thread the persistent installation id
                // (upstream `installation_id.rs::resolve_installation_id`) into
                // the session so the Responses request BODY carries
                // `client_metadata={"x-codex-installation-id": …}` on every
                // request, not just the HTTP header (`client.rs:760-763`).
                installationId: CodexClientIdentity.resolveInstallationId(
                    codexHome: codexHome),
                // persistence-rollout finding 1: thread the client-supplied
                // session start source (`ThreadStartParams.sessionStartSource`)
                // into the config so it flows into the persisted
                // `session_meta.source`. When the client omits it, the store
                // defaults to the app-server default "vscode" (NOT the prior
                // hardcoded "mcp", which upstream's interactive-source filter
                // would have dropped).
                sessionStartSource: p.sessionStartSource)
            // F01 / F-REASONING: log resolved knobs so parity tests can verify
            // each value propagated from `config.toml`. Drop once confirmed in
            // field tests.
            FileHandle.standardError.write(Data("[thread/start] sandbox=\(cfg.sandboxMode.rawValue) approvalPolicy=\(cfg.approvalPolicy.wireValue) reasoning=\(cfg.reasoningEffort ?? "nil") verbosity=\(cfg.textVerbosity ?? "nil")\n".utf8))
            let summary = (try? await store.create(cfg))
                ?? ThreadSummary(id: cfg.threadId, createdAt: 0, ephemeral: cfg.ephemeral,
                                 cwd: cfg.cwd)
            // Durably record the initial remote-environment selection (if
            // any) so resume reconstructs the same binding. Subsequent
            // turn/start env switches append more records; the latest one
            // wins on reconstruct.
            if let env = environment {
                try? await store.record(cfg.threadId,
                                        .environmentRebound(turnId: TurnId.generate(),
                                                            environmentId: env.environmentId,
                                                            execServerUrl: env.execServerUrl))
            }
            await bindAndSubscribe(cfg, conn)
            await reply(conn, id, threadSessionResponse(thread: summary, cfg: cfg))
        case .threadResume(let id, let p):
            let resumeAtCapacity = await supervisor.atCapacity()
            let resumeAlreadyBound = await supervisor.isBound(p.threadId)
            if resumeAtCapacity && !resumeAlreadyBound {
                await conn.send(WireError.overload(id: id)); return
            }
            let rebuilt = try? await store.reconstruct(p.threadId)
            var cfg = rebuilt?.config ?? SessionConfig(
                threadId: p.threadId, cwd: FileManager.default.currentDirectoryPath)
            // prompts finding A/B/C: the AGENTS.md knobs are LIVE-config-derived
            // (upstream reconstructs `Config` fresh on resume — `user_instructions`
            // and the discovery knobs are NOT persisted in the rollout). Re-derive
            // them from the current config + the reconstructed cwd so a resumed
            // thread sees the same global AGENTS.md / fallbacks / root markers /
            // ChildAgentsMd / project_doc_max_bytes as a fresh thread/start.
            let resumeConfig = ConfigLoader(codexHome: codexHome).load()
            let resumeAgentsMd = Self.agentsMdConfig(
                resumeConfig, codexHome: codexHome, cwd: cfg.cwd)
            cfg.agentsMdUserInstructions = resumeAgentsMd.userInstructions
            cfg.agentsMdFilenames = resumeAgentsMd.filenames
            cfg.agentsMdProjectRootMarkers = resumeAgentsMd.projectRootMarkers
            cfg.agentsMdChildEnabled = resumeAgentsMd.childEnabled
            cfg.projectDocMaxBytes = resumeAgentsMd.projectDocMaxBytes
            await bindAndSubscribe(cfg, conn)
            let summary = ThreadSummary(
                id: p.threadId, createdAt: Int64(Date().timeIntervalSince1970),
                ephemeral: cfg.ephemeral, cwd: cfg.cwd)
            await reply(conn, id, threadSessionResponse(thread: summary, cfg: cfg))
        case .threadFork(let id, let p):
            if await supervisor.atCapacity() {
                await conn.send(WireError.overload(id: id)); return
            }
            let src = try? await store.reconstruct(p.threadId)
            let cfg = SessionConfig(
                threadId: ThreadId.generate(),
                cwd: p.cwd ?? src?.config.cwd ?? FileManager.default.currentDirectoryPath,
                model: p.model ?? src?.config.model ?? "gpt-5.5",
                ephemeral: p.ephemeral ?? false,
                notify: src?.config.notify)
            let summary = (try? await store.create(cfg))
                ?? ThreadSummary(id: cfg.threadId, createdAt: 0, ephemeral: cfg.ephemeral,
                                 cwd: cfg.cwd)
            await bindAndSubscribe(cfg, conn)
            await reply(conn, id, threadSessionResponse(thread: summary, cfg: cfg))
        case .threadArchive(let id, let p):
            do {
                let wasActive = ((try? await store.list(archived: false, limit: 1000)) ?? [])
                    .contains { $0.id == p.threadId }
                try await store.archive(p.threadId)
                await reply(conn, id, EmptyResponse())
                if wasActive {
                    await conn.send(ServerNotification.threadArchived(
                        threadId: p.threadId).toMessage())
                }
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to archive thread \(p.threadId.raw): \(error.localizedDescription)"))
            }
        case .threadUnarchive(let id, let p):
            do {
                try await store.unarchive(p.threadId)
                let s = (try? await store.list(archived: false, limit: 1000))?
                    .first(where: { $0.id == p.threadId })
                await reply(conn, id, ["thread": s ?? ThreadSummary(
                    id: p.threadId, createdAt: 0)])
                await conn.send(ServerNotification.threadUnarchived(
                    threadId: p.threadId).toMessage())
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to unarchive thread \(p.threadId.raw): \(error.localizedDescription)"))
            }
        case .threadUnsubscribe(let id, let p):
            if let sinkId = subscriptions.removeValue(forKey: p.threadId) {
                await supervisor.unsubscribe(p.threadId, sinkId)
                await skillsChangeWatchManager.unwatch(conn: conn, threadId: p.threadId)
                await reply(conn, id, ThreadUnsubscribeResponse(status: .unsubscribed))
            } else {
                let status: ThreadUnsubscribeStatus = await supervisor.isBound(p.threadId)
                    ? .notSubscribed
                    : .notLoaded
                await reply(conn, id, ThreadUnsubscribeResponse(status: status))
            }
        case .threadSetName(let id, let p):
            try? await store.setName(p.threadId, p.name)
            await supervisor.broadcast(p.threadId, .threadNameUpdated(threadId: p.threadId, name: p.name))
            await reply(conn, id, EmptyResponse())
        case .threadPinSet(let id, let p):
            try? await store.setPinned(p.threadId, p.pinned)
            await reply(conn, id, EmptyResponse())
        case .gitAction(let id, let p):
            let cwd = await supervisor.currentBoundConfig(p.threadId)?.cwd
                ?? FileManager.default.currentDirectoryPath
            let outcome = await GitDiffRail.perform(
                action: p.action, cwd: cwd, message: p.message, title: p.title, body: p.body)
            await reply(conn, id, outcome)
        case .automationAction(let id, let p):
            guard let astore = AutomationStoreHolder.shared.current() else {
                await reply(conn, id, ["automations": [Automation]()]); break
            }
            switch p.action {
            case "create", "update":
                let aid = p.id ?? UUID().uuidString
                let existing = await astore.get(aid)
                let a = Automation(
                    id: aid, name: p.name ?? existing?.name ?? "Automation",
                    schedule: p.schedule ?? existing?.schedule ?? "manual",
                    prompt: p.prompt ?? existing?.prompt ?? "",
                    enabled: p.enabled ?? existing?.enabled ?? true,
                    cwd: p.cwd ?? existing?.cwd, model: p.model ?? existing?.model,
                    lastRunAt: existing?.lastRunAt, lastThreadId: existing?.lastThreadId)
                await astore.upsert(a)
                await reply(conn, id, ["automation": a])
            case "delete":
                if let aid = p.id { await astore.delete(aid) }
                await reply(conn, id, EmptyResponse())
            case "run":
                if let aid = p.id, let a = await astore.get(aid) {
                    let tid = await runAutomation(a, supervisor: supervisor, store: store,
                                                  defaultCwd: FileManager.default.currentDirectoryPath)
                    await astore.markRan(aid, threadId: tid, at: Int64(Date().timeIntervalSince1970))
                    await reply(conn, id, ["threadId": tid])
                } else { await reply(conn, id, EmptyResponse()) }
            default:
                await reply(conn, id, ["automations": await astore.list()])
            }
        case .outboundSend(let id, let p):
            // OWNER PATH (#7): owner-trusted only. The browser/WebGateway routers
            // are a lower trust tier (allowsOwnerOnlyRPC=false) and must refuse —
            // a process-global PushRouterHolder is reachable from every per-tab
            // router, so this gate is the only thing keeping a web origin from
            // sending owner-authorized push. NOT routed into the WebGateway
            // routerFactory, but the transport flag is the load-bearing guard.
            guard allowsOwnerOnlyRPC else {
                await conn.send(WireError.invalidRequest(id: id, "method not available on this transport"))
                break
            }
            // DENY-DEFAULT: only enabled when codexd built a router (gated on
            // [features].push). A nil holder means the feature is off.
            guard let pushRouter = PushRouterHolder.shared.current() else {
                await conn.send(WireError.invalidRequest(id: id, "push feature is not enabled"))
                break
            }
            let target = p.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else {
                await conn.send(WireError.invalidRequest(id: id, "target is required"))
                break
            }
            guard !p.text.isEmpty else {
                await conn.send(WireError.invalidRequest(id: id, "text is required"))
                break
            }
            // All SSRF/egress containment lives in the PushRouter sinks
            // (EgressGuard chokepoint); the deny REASON is intentionally not
            // surfaced to the caller (info-disclosure) — only ok + a generic
            // detail. Keyless sends are at-least-once-without-dedup; pass an
            // idempotency_key for crash-safe dedup.
            let result = await pushRouter.send(target: target, text: p.text,
                                               idempotencyKey: p.idempotencyKey)
            await reply(conn, id, OutboundSendResponse(ok: result.ok, detail: result.detail))
        case .cronList(let id, _):
            // OWNER PATH (#6): cron schedules UNATTENDED turns + outbound
            // delivery, so the whole family is owner-only — the web tier must not
            // see/modify cron jobs (their prompts + deliverTo targets). Matches
            // outbound/send; defense-in-depth with the WebGateway MethodGate.
            guard allowsOwnerOnlyRPC else {
                await conn.send(WireError.invalidRequest(id: id, "method not available on this transport")); break
            }
            // Deny-default: a nil holder (cron feature off) lists nothing rather
            // than erroring, so an unconfigured daemon answers benignly.
            guard let scheduler = CronSchedulerHolder.shared.current() else {
                await reply(conn, id, CronListResponse(data: [])); break
            }
            let jobs = await scheduler.list().map(CronJobWire.init)
            await reply(conn, id, CronListResponse(data: jobs))
        case .cronAdd(let id, let p):
            guard allowsOwnerOnlyRPC else {
                await conn.send(WireError.invalidRequest(id: id, "method not available on this transport")); break
            }
            guard let scheduler = CronSchedulerHolder.shared.current() else {
                await conn.send(WireError.invalidRequest(id: id, "cron feature is not enabled")); break
            }
            // Bound inputs before they hit the durable JSON store.
            guard p.prompt.utf8.count <= 100_000 else {
                await conn.send(WireError.invalidRequest(id: id, "prompt too long (max 100 KiB)")); break
            }
            // A deliverTo must be a well-formed, bounded PushTarget — validated
            // here so a malformed target can't be persisted and fail every fire.
            if let dt = p.deliverTo, !dt.isEmpty {
                guard dt.utf8.count <= 1024 else {
                    await conn.send(WireError.invalidRequest(id: id, "deliverTo too long")); break
                }
                guard PushTarget.parse(dt) != nil else {
                    await conn.send(WireError.invalidRequest(id: id, "invalid deliverTo target")); break
                }
            }
            guard let schedule = p.schedule.toSchedule() else {
                await conn.send(WireError.invalidRequest(id: id, "invalid schedule")); break
            }
            let jid = p.id ?? UUID().uuidString
            let existing = await scheduler.job(jid)
            let job = CronJob(
                id: jid, schedule: schedule, prompt: p.prompt,
                enabled: p.enabled ?? existing?.enabled ?? true,
                skipMemory: p.skipMemory ?? existing?.skipMemory ?? true,
                deliverTo: (p.deliverTo?.isEmpty == true ? nil : p.deliverTo) ?? existing?.deliverTo,
                lastRunAt: existing?.lastRunAt,
                createdAt: existing?.createdAt ?? Int64(Date().timeIntervalSince1970))
            await scheduler.upsert(job)
            await reply(conn, id, CronJobWire(job))
        case .cronRemove(let id, let p):
            guard allowsOwnerOnlyRPC else {
                await conn.send(WireError.invalidRequest(id: id, "method not available on this transport")); break
            }
            guard let scheduler = CronSchedulerHolder.shared.current() else {
                await reply(conn, id, EmptyResponse()); break
            }
            await scheduler.remove(p.id)
            await reply(conn, id, EmptyResponse())
        case .channelsList(let id, _), .channelStatus(let id, _):
            // OWNER PATH (#1): channels run UNTRUSTED inbound senders against the
            // daemon; their control surface (list/start/stop/status) is owner-only.
            guard allowsOwnerOnlyRPC else {
                await conn.send(WireError.invalidRequest(id: id, "method not available on this transport")); break
            }
            // Deny-default: a nil holder (channels off) lists nothing.
            guard let manager = ChannelManagerHolder.shared.current() else {
                await reply(conn, id, ChannelStatusListResponse(data: [])); break
            }
            // Optional id filter (channels/status with an id).
            var statuses = await manager.status().map(ChannelGlue.wire)
            if case .channelStatus(_, let p) = parsed, let wanted = p.id {
                statuses = statuses.filter { $0.id == wanted }
            }
            await reply(conn, id, ChannelStatusListResponse(data: statuses))
        case .channelStart(let id, let p):
            guard allowsOwnerOnlyRPC else {
                await conn.send(WireError.invalidRequest(id: id, "method not available on this transport")); break
            }
            guard let manager = ChannelManagerHolder.shared.current() else {
                await conn.send(WireError.invalidRequest(id: id, "channels feature is not enabled")); break
            }
            guard await manager.registered().contains(p.id) else {
                await conn.send(WireError.invalidRequest(id: id, "unknown channel '\(p.id)'")); break
            }
            await manager.start(p.id)
            let status = await manager.status(p.id).map { [ChannelGlue.wire($0)] } ?? []
            await reply(conn, id, ChannelStatusListResponse(data: status))
        case .channelStop(let id, let p):
            guard allowsOwnerOnlyRPC else {
                await conn.send(WireError.invalidRequest(id: id, "method not available on this transport")); break
            }
            guard let manager = ChannelManagerHolder.shared.current() else {
                await reply(conn, id, EmptyResponse()); break
            }
            await manager.stop(p.id)
            await reply(conn, id, EmptyResponse())
        case .threadList(let id, let p):
            let list = (try? await store.list(archived: p.archived ?? false,
                                               limit: p.limit ?? 50)) ?? []
            await reply(conn, id, ["data": list])
        case .threadLoadedList(let id, _):
            let ids = await store.loadedList()
            await reply(conn, id, .object(["data": .array(ids.map { .string($0) }),
                                            "nextCursor": .null]))
        case .threadRead(let id, let p):
            let rebuilt = try? await store.reconstruct(p.threadId)
            var summary = ThreadSummary(id: p.threadId,
                                         createdAt: Int64(Date().timeIntervalSince1970),
                                         ephemeral: rebuilt?.config.ephemeral ?? false,
                                         cwd: rebuilt?.config.cwd
                                             ?? FileManager.default.currentDirectoryPath)
            summary.name = try? await store.name(p.threadId)
            summary.gitInfo = ((try? await store.gitInfo(p.threadId)) ?? nil)?.json
            if p.includeTurns == true, let rebuilt {
                summary.turns = rebuilt.turns.map(Self.turnJSON)
            }
            await reply(conn, id, ThreadResultEnvelope(thread: summary))
        case .threadTurnsList(let id, let p):
            let turns = (try? await store.turnsList(p.threadId)) ?? []
            await reply(conn, id, .object([
                "data": .array(turns.map(Self.turnJSON)),
                "nextCursor": .null, "backwardsCursor": .null]))
        case .threadTurnsItemsList(let id, let p):
            // NOTE (audit app-server-registry/finding-3): upstream stubs this as
            // -32601 "thread/turns/items/list is not supported yet"
            // (thread_processor.rs:619-626). The port DELIBERATELY diverges and
            // returns real items from the store — a forward-compatible enhancement.
            // The method is still gated experimental (ExperimentalGate.defaultMethods),
            // so only experimentalApi clients can reach it; no upstream-fidelity
            // client depends on the -32601 stub. Covered by
            // EndToEndTests.testFullStreamedTurnEndToEnd (asserts a success
            // response carrying real `data` items for thread/turns/items/list).
            let items = (try? await store.turnItems(p.threadId, turn: p.turnId)) ?? []
            let data = items.compactMap { try? JSONBridge.value($0) }
            await reply(conn, id, .object(["data": .array(data),
                                            "nextCursor": .null, "backwardsCursor": .null]))
        case .threadInjectItems(let id, let p):
            guard p.threadId.isWellFormed else {
                await conn.send(WireError.invalidRequest(id: id, "invalid threadId"))
                return
            }
            guard await threadExists(p.threadId) else {
                await conn.send(WireError.invalidRequest(
                    id: id, "thread/inject_items thread not found: \(p.threadId.raw)"))
                return
            }
            do {
                try await store.injectItems(p.threadId, p.items)
                if await supervisor.isBound(p.threadId) {
                    let textItems = await store.injectedItemTexts(p.items)
                    _ = await supervisor.submit(p.threadId, .injectAssistantText(textItems))
                }
                await reply(conn, id, EmptyResponse())
            } catch {
                await conn.send(WireError.invalidRequest(id: id, String(describing: error)))
            }
        case .threadRollback(let id, let p):
            guard p.threadId.isWellFormed else {
                await conn.send(WireError.invalidRequest(id: id, "invalid threadId"))
                return
            }
            guard p.numTurns >= 1 else {
                await conn.send(WireError.invalidRequest(
                    id: id, "thread/rollback numTurns must be >= 1"))
                return
            }
            guard await threadExists(p.threadId) else {
                await conn.send(WireError.invalidRequest(
                    id: id, "thread/rollback thread not found: \(p.threadId.raw)"))
                return
            }
            do {
                let turns = try await store.rollback(p.threadId, numTurns: p.numTurns)
                if await supervisor.isBound(p.threadId) {
                    _ = await supervisor.submit(p.threadId, .rollbackUserTurns(p.numTurns))
                }
                await reply(conn, id, .object(["thread": .object([
                    "id": .string(p.threadId.raw),
                    "turns": .array(turns.map(Self.turnJSON))])]))
            } catch {
                await conn.send(WireError.invalidRequest(id: id, String(describing: error)))
            }

        // MARK: goals
        case .threadGoalSet(let id, let p):
            if let g = try? await store.goalSet(p.threadId, objective: p.objective,
                                                 status: p.status, tokenBudget: p.tokenBudget) {
                let goal = g.toProtocol()
                await supervisor.broadcast(p.threadId,
                    .threadGoalUpdated(threadId: p.threadId, turnId: nil, goal: goal))
                await reply(conn, id, ThreadGoalSetResponse(goal: goal))
            } else {
                await conn.send(WireError.internalError(id: id, "goal set failed"))
            }
        case .threadGoalGet(let id, let p):
            let g = try? await store.goalGet(p.threadId)
            await reply(conn, id, ThreadGoalGetResponse(goal: g?.toProtocol()))
        case .threadGoalClear(let id, let p):
            let cleared = (try? await store.goalClear(p.threadId)) ?? false
            if cleared { await supervisor.broadcast(p.threadId, .threadGoalCleared(threadId: p.threadId)) }
            await reply(conn, id, ThreadGoalClearResponse(cleared: cleared))

        // MARK: memory
        case .threadMemoryModeSet(let id, let p):
            try? await store.setMemoryMode(p.threadId, p.mode)
            await reply(conn, id, EmptyResponse())
        case .memoryReset(let id):
            await memoryResetHandler?()
            await reply(conn, id, EmptyResponse())

        // MARK: wiki (Memory Wiki RPC surface) — per-method arms + helpers live
        // in RequestRouter+Wiki.swift so the (growing) wiki/* surface stays out
        // of this file. Adding a wiki method: add the ClientRequest case, add it
        // to this grouped case, and add an arm in dispatchWiki(_:_:).
        case .wikiList, .wikiPageGet, .wikiSearch, .wikiGraph, .wikiBacklinks,
             .wikiEntityBacklinks, .wikiTags, .wikiIndex, .wikiPageUpsert,
             .wikiPageDelete, .wikiPageRename, .wikiBrief, .wikiQuery, .wikiStatus, .wikiWatchList,
             .wikiResearchStart, .wikiIngestStart:
            await dispatchWiki(parsed, conn)

        // MARK: turns
        case .turnStart(let id, let p):
            if let environments = p.environments,
               let remote = selectedRemoteEnvironment(environments) {
                // Source of truth for the currently-bound env is the
                // supervisor (in-memory), not the rollout (which lags writes
                // by group-commit). Fall back to reconstruct for cwd/etc.
                let liveEnv = await supervisor.currentRemoteEnvironment(p.threadId)
                if liveEnv != remote {
                    // The requested environment differs from the binding the
                    // thread is currently on. Accept the switch at the turn
                    // boundary (approach B in
                    // evaluation/codex-macos-swift-remote-execution-completion.md):
                    // persist a `.environmentRebound` record so resume sees
                    // the new selection, then ask the supervisor to replace
                    // the worker. In-flight remote tool work on the old
                    // environment is severed by the worker swap; the next
                    // turn runs cleanly on the new env.
                    try? await store.record(
                        p.threadId,
                        .environmentRebound(turnId: TurnId.generate(),
                                            environmentId: remote.environmentId,
                                            execServerUrl: remote.execServerUrl))
                    var baseConfig = await supervisor.currentBoundConfig(p.threadId)
                    if baseConfig == nil {
                        baseConfig = (try? await store.reconstruct(p.threadId))?.config
                    }
                    if var newConfig = baseConfig {
                        newConfig.remoteEnvironment = remote
                        await supervisor.rebindRemoteEnvironment(p.threadId,
                                                                 newConfig: newConfig)
                    }
                }
            }
            // Allocate the turn id HERE, before submit, and thread it into the
            // engine op so `startSpecial`/`runTurn` use it verbatim as the
            // engine turn/submission id. This makes the `turn/start` response
            // `turn.id` equal the id carried by every subsequent turn/started,
            // turn/completed, and item/* notification — and the id the client
            // echoes in `turn/steer.expectedTurnId` / `turn/interrupt.turnId`.
            // Previously this allocated an UNRELATED id while the engine
            // generated its own, so the response id correlated with nothing.
            let allocatedTurnId = TurnId.generate()
            let turn = TurnObject(id: allocatedTurnId, status: .inProgress)
            guard await supervisor.submit(p.threadId, .startTurn(input: p.input, model: p.model, turnId: allocatedTurnId)) else {
                await conn.send(WireError.overload(id: id))
                return
            }
            await reply(conn, id, ["turn": turn])
        case .turnInterrupt(let id, let p):
            guard await supervisor.submit(p.threadId, .interrupt(turnId: p.turnId)) else {
                await conn.send(WireError.overload(id: id))
                return
            }
            await reply(conn, id, EmptyResponse())
        case .turnSteer(let id, let p):
            // Synchronous request validation (upstream `turn_steer_inner`,
            // turn_processor.rs:621-723). The empty-`expectedTurnId` guard
            // (invalid_request, -32600) and the v2 input-length guard
            // (invalid_params, -32602) both fire before the steer op is
            // submitted. The state-dependent steer errors — NoActiveTurn,
            // ExpectedTurnMismatch, EmptyInput, and the review/compact-only
            // ActiveTurnNotSteerable (upstream `Session::steer_input`,
            // session/mod.rs:3112) — are produced by the engine (SessionEngine
            // `.steer` handler) and surfaced as `.error` notifications, since
            // the live turn state resides in the (possibly out-of-process)
            // worker and is not readable here for a synchronous JSON-RPC reply.
            if p.expectedTurnId.raw.isEmpty {
                await conn.send(WireError.invalidRequest(id: id, "expectedTurnId must not be empty"))
                return
            }
            // `text_char_count`: count Unicode scalar values (Rust `char`s)
            // across all text input items; non-text items contribute 0.
            let actualChars = p.input.reduce(0) { $0 + ($1.text?.unicodeScalars.count ?? 0) }
            if actualChars > WireError.maxUserInputTextChars {
                await conn.send(WireError.inputTooLargeV2(id: id, actualChars: actualChars))
                return
            }
            guard await supervisor.submit(p.threadId, .steer(input: p.input, expectedTurnId: p.expectedTurnId)) else {
                await conn.send(WireError.overload(id: id))
                return
            }
            await reply(conn, id, TurnSteerResponse(turnId: p.expectedTurnId))
        case .threadCompactStart(let id, let p):
            guard await supervisor.submit(p.threadId, .compactNow) else {
                await conn.send(WireError.overload(id: id))
                return
            }
            await reply(conn, id, EmptyResponse())
        case .threadShellCommand(let id, let p):
            let command = p.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                await conn.send(WireError.invalidRequest(id: id, "command must not be empty"))
                return
            }
            guard await supervisor.submit(p.threadId, .runShellCommand(command)) else {
                await conn.send(WireError.overload(id: id))
                return
            }
            await reply(conn, id, EmptyResponse())
        case .reviewStart(let id, let p):
            // For base-branch reviews, pre-resolve the merge-base SHA with git
            // (using the thread's cwd) so the model receives the primary
            // `BASE_BRANCH_PROMPT` with a directly runnable `git diff <sha>`
            // instruction, mirroring upstream `review_prompt` →
            // `merge_base_with_head`. When git access fails (or there is no
            // base-branch target) we fall through to the BACKUP form.
            // Upstream `review_prompt` bails when a custom review target has
            // empty/whitespace-only instructions ("Review prompt cannot be
            // empty"); reject before submitting a turn rather than silently
            // falling back to the uncommitted-changes prompt.
            if p.customReviewIsEmpty {
                await conn.send(WireError.invalidRequest(id: id, "Review prompt cannot be empty"))
                return
            }
            let reviewInput: [TurnInput]
            if let branch = p.baseBranchTarget {
                let reviewCwd = (try? await store.reconstruct(p.threadId))?.config.cwd
                    ?? FileManager.default.currentDirectoryPath
                let sha = branch.isEmpty
                    ? nil
                    : await GitUtils(cwd: reviewCwd).mergeBaseWithHead(branch)
                reviewInput = [TurnInput(text: p.reviewPrompt(mergeBaseSha: sha))]
            } else {
                reviewInput = p.reviewInput
            }
            guard await supervisor.submit(p.threadId, .review(
                input: reviewInput,
                prompt: p.reviewInstructions,
                userFacingHint: p.userFacingHint)) else {
                await conn.send(WireError.overload(id: id))
                return
            }
            await reply(conn, id, .object([
                "reviewThreadId": .string(p.threadId.raw),
                "turn": (try? JSONBridge.value(
                    TurnObject(id: TurnId.generate(), status: .inProgress))) ?? .object([:]),
            ]))

        // MARK: models / config / account / skills / mcp / collab / apps / features
        case .modelList(let id, _):
            let cat = ModelCatalog.default
            await reply(conn, id, ModelListResponse(
                data: cat.listed().map {
                    ModelInfo(id: $0.slug, model: $0.slug,
                              displayName: $0.displayName,
                              description: $0.description,
                              hidden: $0.hidden, isDefault: $0.isDefault)
                }, nextCursor: nil))
        case .modelProviderCapabilitiesRead(let id):
            await reply(conn, id, ModelProviderCapabilitiesReadResponse(
                namespaceTools: true, imageGeneration: false, webSearch: true))
        case .configRead(let id, let params):
            let toJSON = Self.configValueToJSON
            // Honor `cwd`: resolve project (`.codex/`) layers as seen from that
            // directory (upstream `ConfigReadParams.cwd`).
            let effectiveConfig = ConfigLoader(codexHome: codexHome,
                                               cwdOverride: params.cwd).load()
            // A fatal load error (e.g. a profile-v2 name colliding with a
            // legacy `[profiles.<name>]`) is `io::ErrorKind::InvalidData`
            // upstream (loader/mod.rs:227-243); surface it as invalidRequest
            // instead of returning a partially-applied config.
            if let loadError = effectiveConfig.loadError {
                await conn.send(WireError.invalidRequest(id: id, loadError))
                return
            }
            // Project the merged map onto upstream's typed v2 `Config` wire
            // shape: drop unknown (non-ConfigToml) top-level keys and emit every
            // named v2 field explicitly (null when unset). Mirrors upstream's
            // `try_into::<ConfigToml>()` → `from_value::<Config>()` round-trip
            // (config_manager_service.rs:127-139).
            var configJSON = effectiveConfig.configProjectionJSON().mapValues(toJSON)
            configJSON["features"] = runtimeFeaturesJSON(base: configJSON["features"],
                                                         config: effectiveConfig)
            // Honor `includeLayers`: emit the ordered `ConfigLayer` stack
            // (each `{name: ConfigLayerSource, version, config}`) HIGHEST
            // precedence first and INCLUDING empty real layers, matching
            // upstream `get_layers(HighestPrecedenceFirst, include_disabled:
            // true)` (config_manager_service.rs:141-150). Only the synthetic
            // `defaults` layer (no `source`) is excluded — upstream never
            // surfaces it as a layer.
            // Emit a `configWarning` notification for each project-local
            // ignored-config-keys warning collected during load (upstream
            // app-server/src/lib.rs:582-593 turns each `startup_warnings` entry
            // into a `configWarning`). The loader is sink-less, so the warnings
            // ride out on the `Config` value and are fanned out here.
            for w in effectiveConfig.configWarnings {
                await conn.send(ServerNotification.configWarning(
                    summary: w.summary, details: w.details, path: w.path).toMessage())
            }
            var replyObj: [String: JSONValue] = [
                "config": .object(configJSON),
                "origins": .object(effectiveConfig.originsJSON().mapValues(toJSON)),
            ]
            // Upstream `ConfigReadResponse.layers` carries
            // `#[serde(skip_serializing_if = "Option::is_none")]`
            // (app-server-protocol/v2/config.rs:374-375), so the `layers` key is
            // ABSENT (not null) when `includeLayers` is false.
            if params.includeLayers == true {
                replyObj["layers"] = .array(
                    effectiveConfig.layers.reversed().compactMap { layer -> JSONValue? in
                    guard let src = layer.source else { return nil }
                    // Upstream computes each layer's `version` via
                    // `version_for_toml` over the RAW TOML value it was loaded
                    // from (config/src/state.rs:107-117), not over the
                    // alias-normalized/projected layer map. Hash the raw file
                    // content so the user-layer version reported here matches
                    // the one `config/value/write` compares `expectedVersion`
                    // against (see `userLayerVersion`).
                    let version = Self.rawLayerVersion(source: src, fallback: layer.values)
                    var layerObj: [String: JSONValue] = [
                        "name": toJSON(src.toJSON()),
                        "version": .string(version),
                        "config": .object(layer.values.mapValues(toJSON)),
                    ]
                    // Upstream `ConfigLayer.disabled_reason` carries
                    // `#[serde(skip_serializing_if = "Option::is_none")]`
                    // (v2/config.rs:302-303): present only for a DISABLED
                    // (untrusted) project layer, absent otherwise.
                    if let reason = layer.disabledReason {
                        layerObj["disabledReason"] = .string(reason)
                    }
                    return JSONValue.object(layerObj)
                })
            }
            await reply(conn, id, .object(replyObj))
        case .getAccount(let id, let params):
            do {
                await reply(conn, id, try await getAccountResponse(
                    refreshToken: params.refreshToken ?? false))
            } catch is MissingChatgptAccountDetails {
                await conn.send(WireError.invalidRequest(
                    id: id,
                    "email and plan type are required for chatgpt authentication"))
            } catch {
                await conn.send(WireError.invalidRequest(
                    id: id, "\(error)"))
            }
        case .getAccountRateLimits(let id):
            guard let auth else {
                await conn.send(WireError.invalidRequest(
                    id: id, "codex account authentication required to read rate limits"))
                return
            }
            guard let tokens = await auth.storedTokens() else {
                await conn.send(WireError.invalidRequest(
                    id: id, "codex account authentication required to read rate limits"))
                return
            }
            guard tokens.tokenType != "APIKey" else {
                await conn.send(WireError.invalidRequest(
                    id: id, "chatgpt authentication required to read rate limits"))
                return
            }
            do {
                let result = try await accountRateLimitsFetcher(
                    tokens, Self.chatGPTBaseURL(codexHome: codexHome))
                // Upstream's get_account_rate_limits_response only returns the
                // GetAccountRateLimitsResponse; the AccountRateLimitsUpdated
                // notification is emitted exclusively from in-turn
                // token-usage events (bespoke_event_handling.rs:1573), never
                // from this read handler.
                await reply(conn, id, result)
            } catch {
                // Upstream maps a backend fetch failure / empty snapshots to
                // `internal_error` (-32603) (account_processor.rs:927,929), not
                // invalid_request. The auth-precondition rejections above keep
                // invalid_request to match upstream.
                await conn.send(WireError.internalError(
                    id: id, "failed to fetch codex rate limits: \(error.localizedDescription)"))
            }
        case .skillsList(let id, let p):
            let recs = SkillsDiscovery().discover(
                codexHome: codexHome,
                cwds: p.cwds ?? [FileManager.default.currentDirectoryPath],
                extraRoots: extraSkillRoots)
            await reply(conn, id, SkillsListResponse(data: recs.map {
                SkillSummary(name: $0.name, description: $0.description, path: $0.path)
            }))
        case .skillsExtraRootsSet(let id, let p):
            // Upstream models each entry as an `AbsolutePathBuf`; reject relative
            // entries rather than silently resolving against an ambiguous cwd.
            let nonAbsolute = p.extraRoots.filter { !$0.hasPrefix("/") }
            guard nonAbsolute.isEmpty else {
                await conn.send(WireError.invalidRequest(id: id,
                    "skills extra roots must be absolute paths: \(nonAbsolute.joined(separator: ", "))"))
                return
            }
            extraSkillRoots = p.extraRoots
            await reply(conn, id, EmptyResponse())
        case .threadDelete(let id, let p):
            do {
                // Stop the worker + tear down supervisor state BEFORE removing the
                // row/file, so a mid-flight turn cannot revive the rollout
                // (write-after-free). evictDeletedThread emits `thread/deleted` to
                // any current subscribers and is a no-op for an unloaded thread.
                await supervisor.evictDeletedThread(p.threadId)
                let existed = try await store.delete(p.threadId)
                // Drop router-side subscription + skills-change watch state so no
                // residue points at a tombstoned thread.
                if let sinkId = subscriptions.removeValue(forKey: p.threadId) {
                    await supervisor.unsubscribe(p.threadId, sinkId)
                }
                await skillsChangeWatchManager.unwatch(conn: conn, threadId: p.threadId)
                await reply(conn, id, EmptyResponse())
                // Belt-and-suspenders: if a peer connection is subscribed (the
                // eviction sweep already delivered to current subscribers; this
                // re-broadcast is a no-op when none remain), still signal them.
                if existed { await supervisor.broadcast(p.threadId, .threadDeleted(threadId: p.threadId)) }
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to delete thread \(p.threadId.raw): \(error.localizedDescription)"))
            }
        case .permissionProfileList(let id, let p):
            do {
                await reply(conn, id, try Self.permissionProfileListResponse(
                    params: p, codexHome: codexHome))
            } catch let e as PermissionProfileListError {
                await conn.send(WireError.invalidRequest(id: id, e.message))
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to reload config: \(error.localizedDescription)"))
            }
        case .getAccountTokenUsage(let id):
            guard let auth, let tokens = await auth.storedTokens() else {
                await conn.send(WireError.invalidRequest(
                    id: id, "codex account authentication required to read token usage"))
                return
            }
            guard tokens.tokenType != "APIKey" else {
                await conn.send(WireError.invalidRequest(
                    id: id, "chatgpt authentication required to read token usage"))
                return
            }
            do {
                let result = try await accountTokenUsageFetcher(
                    tokens, Self.chatGPTBaseURL(codexHome: codexHome))
                await reply(conn, id, result)
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to fetch token usage profile: \(error.localizedDescription)"))
            }
        case .mcpServerStatusList(let id, _):
            await ensureMcpServersStarted(conn: conn)
            await reply(conn, id, await mcpStatusListResponse())
        case .collaborationModeList(let id):
            await reply(conn, id, Self.collaborationModeListResponse())
        case .appsList(let id, let params):
            do {
                let response = try Self.appsListResponse(
                    codexHome: codexHome,
                    params: params,
                    runtimeFeatureEnablement: runtimeFeatureEnablement)
                if !response.data.isEmpty {
                    await conn.send(.notification(JSONRPCNotification(
                        method: "app/list/updated",
                        params: .object(["data": .array(response.data)]))))
                }
                await reply(conn, id, response)
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
        case .experimentalFeatureList(let id):
            await reply(conn, id, experimentalFeatureListResponse())
        case .configRequirementsRead(let id):
            do {
                let requirements: JSONValue = try requirementsLoader.load()
                    .map { .object($0.mapValues(Self.configValueToJSON(_:))) }
                    ?? JSONValue.null
                await reply(conn, id, .object(["requirements": requirements]))
            } catch {
                await conn.send(WireError.invalidRequest(
                    id: id, "failed to load config requirements: \(error.localizedDescription)"))
            }

        // MARK: generic (peripheral / experimental) — faithful default shape
        case .generic(let id, let method, let params):
            if await handleFilesystemRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleCommandExecRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleProcessRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleThreadMetadataRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleThreadBackgroundTerminalsCleanRequest(
                id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleThreadElicitationRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleFuzzyFileSearchRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleSkillsConfigWriteRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleConfigWriteRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleFeedbackUploadRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleHooksRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handlePluginRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleMarketplaceRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleExternalAgentConfigRequest(id: id, method: method,
                                                      params: params, conn: conn) {
                return
            }
            if await handleMcpServerRequest(id: id, method: method,
                                            params: params, conn: conn) {
                return
            }
            if await handleGitRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleConversationSummaryRequest(id: id, method: method,
                                                      params: params, conn: conn) {
                return
            }
            if await handleGetAuthStatusRequest(id: id, method: method,
                                                params: params, conn: conn) {
                return
            }
            if await handleSendAddCreditsNudgeEmailRequest(id: id, method: method,
                                                           params: params, conn: conn) {
                return
            }
            if await handleExperimentalFeatureEnablementRequest(id: id, method: method,
                                                                params: params, conn: conn) {
                return
            }
            if await handleRemoteControlRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleEnvironmentRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if await handleRealtimeRequest(id: id, method: method, params: params, conn: conn) {
                return
            }
            if let auth {
                switch method {
                case "account/login/start":
                    let loginType = params?["type"]?.stringValue ?? "chatgpt"
                    // forced_login_method / external-auth guards, mirroring
                    // account_processor.rs:251-266, 309-318, 556-563.
                    let forcedLoginMethod = ConfigLoader(codexHome: codexHome)
                        .load().string("forced_login_method")?.lowercased()
                    let externalAuthActive = (await auth.storedTokens())?.tokenType
                        .caseInsensitiveCompare("BearerExternal") == .orderedSame
                    switch loginType {
                    case "apiKey":
                        if externalAuthActive {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "External auth is active. Use account/login/start (chatgptAuthTokens) to update it or account/logout to clear it."))
                            return
                        }
                        if forcedLoginMethod == "chatgpt" {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "API key login is disabled. Use ChatGPT login instead."))
                            return
                        }
                        guard let apiKey = params?["apiKey"]?.stringValue, !apiKey.isEmpty else {
                            await conn.send(WireError.invalidRequest(
                                id: id, "account/login/start apiKey requires apiKey"))
                            return
                        }
                        do {
                            try await auth.loginWithAPIKey(apiKey)
                            await reply(conn, id, .object(["type": .string("apiKey")]))
                            await conn.send(ServerNotification.accountLoginCompleted(
                                loginId: nil, success: true, error: nil).toMessage())
                            await conn.send(ServerNotification.accountUpdated(
                                authMode: "apikey", planType: nil).toMessage())
                        } catch {
                            // Upstream maps a persistence failure here to
                            // `internal_error` (-32603) (account_processor.rs:285),
                            // not invalid_request.
                            await conn.send(WireError.internalError(
                                id: id, "failed to save api key: \(error.localizedDescription)"))
                        }
                    case "chatgptAuthTokens":
                        if forcedLoginMethod == "api" {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "External ChatGPT auth is disabled. Use API key login instead."))
                            return
                        }
                        guard let accessToken = params?["accessToken"]?.stringValue,
                              !accessToken.isEmpty,
                              let accountId = params?["chatgptAccountId"]?.stringValue,
                              !accountId.isEmpty else {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "account/login/start chatgptAuthTokens requires accessToken and chatgptAccountId"))
                            return
                        }
                        // Enforce `forced_chatgpt_workspace_id`
                        // (account_processor.rs:573-579): when configured, an
                        // external ChatGPT token whose workspace/account id is
                        // not in the allow-list is rejected before persisting,
                        // with the verbatim upstream message.
                        if let expected = Self.forcedChatgptWorkspaceIds(codexHome: codexHome),
                           !expected.contains(accountId) {
                            let listDebug = "[" + expected
                                .map { "\"\($0)\"" }.joined(separator: ", ") + "]"
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "External auth must use one of workspace(s) \(listDebug), but received \"\(accountId)\"."))
                            return
                        }
                        // Upstream (`from_external_tokens`) canonicalizes the
                        // client-supplied plan via `PlanType::from_raw_value`,
                        // defaulting to "unknown" when absent.
                        let planType = AccountPlanType.wireValue(
                            forRawClaim: params?["chatgptPlanType"]?.stringValue)
                        do {
                            try await auth.loginWithExternalChatGPTTokens(
                                accessToken: accessToken, accountId: accountId)
                            await reply(conn, id, .object(["type": .string("chatgptAuthTokens")]))
                            await conn.send(ServerNotification.accountLoginCompleted(
                                loginId: nil, success: true, error: nil).toMessage())
                            await conn.send(ServerNotification.accountUpdated(
                                authMode: "chatgptAuthTokens", planType: planType).toMessage())
                        } catch {
                            // Upstream `login_with_chatgpt_auth_tokens` maps a
                            // failure to `internal_error` (-32603) with the message
                            // prefix "failed to set external auth:"
                            // (account_processor.rs:587).
                            await conn.send(WireError.internalError(
                                id: id, "failed to set external auth: \(error.localizedDescription)"))
                        }
                    case "chatgpt":
                        if externalAuthActive {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "External auth is active. Use account/login/start (chatgptAuthTokens) to update it or account/logout to clear it."))
                            return
                        }
                        if forcedLoginMethod == "api" {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "ChatGPT login is disabled. Use API key login instead."))
                            return
                        }
                        let connection = ObjectIdentifier(conn as AnyObject)
                        if let oldLoginId = pendingLoginIds[connection],
                           let oldPending = pendingDeviceLogins.removeValue(forKey: oldLoginId) {
                            oldPending.task.cancel()
                        }
                        if let oldLoginId = pendingLoginIds[connection],
                           let oldPending = pendingBrowserLogins.removeValue(forKey: oldLoginId) {
                            oldPending.timeoutTask.cancel()
                            oldPending.server.stop()
                        }
                        let loginId = UUID().uuidString.lowercased()
                        // codex_streamlined_login (default false) only changes
                        // the in-browser post-callback success page, not the
                        // JSON-RPC auth_url. Threaded into the callback server
                        // mirroring account_processor.rs:320-329 and
                        // login/src/server.rs:887-889.
                        let codexStreamlinedLogin =
                            params?["codexStreamlinedLogin"]?.boolValue ?? false
                        do {
                            let server = try ChatGPTLoginCallbackServer(
                                codexStreamlinedLogin: codexStreamlinedLogin
                            ) { [weak self] values in
                                guard let self else {
                                    return .failure("Login server stopped.", status: 503)
                                }
                                return await self.finishBrowserLogin(loginId: loginId,
                                                                     auth: auth,
                                                                     values: values,
                                                                     conn: conn)
                            }
                            let redirectURI = "http://localhost:\(server.port)/auth/callback"
                            let s = await auth.loginStart(redirectURI: redirectURI)
                            pendingLoginIds[connection] = loginId
                            let timeoutTask = Task { [weak self] in
                                try? await Task.sleep(for: .seconds(600))
                                guard !Task.isCancelled, let self else { return }
                                await self.timeoutBrowserLogin(loginId: loginId, conn: conn)
                            }
                            pendingBrowserLogins[loginId] = PendingBrowserLogin(
                                connection: connection,
                                server: server,
                                timeoutTask: timeoutTask)
                            await reply(conn, id, .object([
                                "type": .string("chatgpt"),
                                "authUrl": .string(s.authorizeURL),
                                "loginId": .string(loginId)]))
                        } catch {
                            await conn.send(WireError.invalidRequest(
                                id: id, "failed to start login server: \(error)"))
                        }
                    case "chatgptDeviceCode":
                        if externalAuthActive {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "External auth is active. Use account/login/start (chatgptAuthTokens) to update it or account/logout to clear it."))
                            return
                        }
                        if forcedLoginMethod == "api" {
                            await conn.send(WireError.invalidRequest(
                                id: id,
                                "ChatGPT login is disabled. Use API key login instead."))
                            return
                        }
                        switch await auth.deviceCodeStart() {
                        case .success(let challenge):
                            let loginId = UUID().uuidString.lowercased()
                            let connection = ObjectIdentifier(conn as AnyObject)
                            if let oldLoginId = pendingLoginIds[connection],
                               let oldPending = pendingDeviceLogins.removeValue(forKey: oldLoginId) {
                                oldPending.task.cancel()
                            }
                            if let oldLoginId = pendingLoginIds[connection],
                               let oldPending = pendingBrowserLogins.removeValue(forKey: oldLoginId) {
                                oldPending.timeoutTask.cancel()
                                oldPending.server.stop()
                            }
                            pendingLoginIds[connection] = loginId
                            let task = Task { [weak self] in
                                guard let self else { return }
                                await self.finishDeviceCodeLogin(
                                    loginId: loginId,
                                    auth: auth,
                                    challenge: challenge,
                                    conn: conn)
                            }
                            pendingDeviceLogins[loginId] = PendingDeviceLogin(
                                connection: connection,
                                task: task)
                            await reply(conn, id, .object([
                                "type": .string("chatgptDeviceCode"),
                                "loginId": .string(loginId),
                                "verificationUrl": .string(challenge.verificationURL),
                                "userCode": .string(challenge.userCode)]))
                        case .failure(let error):
                            // Mirror login_chatgpt_device_code_start_error
                            // (account_processor.rs:344-351): a NotFound
                            // condition (device-code login not enabled, HTTP 404)
                            // maps to invalid_request with the error's own
                            // message; any other failure is a transient
                            // internal_error prefixed "failed to request device
                            // code:".
                            if case .deviceCodeNotEnabled(let message) = error {
                                await conn.send(WireError.invalidRequest(id: id, message))
                            } else {
                                await conn.send(WireError.internalError(
                                    id: id, "failed to request device code: \(error)"))
                            }
                        }
                    default:
                        await conn.send(WireError.invalidRequest(
                            id: id, "unsupported account login type \(loginType)"))
                    }
                    return
                case "account/login/cancel":
                    let requestedLoginId = params?["loginId"]?.stringValue
                    let connection = ObjectIdentifier(conn as AnyObject)
                    let loginId = requestedLoginId ?? pendingLoginIds[connection]
                    var canceled = false
                    // Tracks whether the cancelled login was a browser login. The
                    // completion notification's error text differs by login kind:
                    // a browser login-server shutdown wraps the io::Error as
                    // "Login server error: Login was not completed"
                    // (account_processor.rs:397-398 over login/server.rs:195-196),
                    // whereas device-code cancellation emits the bare
                    // "Login was not completed" (account_processor.rs:466-468).
                    var canceledBrowser = false
                    if let loginId,
                       let pending = pendingDeviceLogins[loginId],
                       pending.connection == connection {
                        pendingDeviceLogins.removeValue(forKey: loginId)
                        pending.task.cancel()
                        if pendingLoginIds[connection] == loginId {
                            pendingLoginIds.removeValue(forKey: connection)
                        }
                        canceled = true
                    } else if let loginId,
                              let pending = pendingBrowserLogins[loginId],
                              pending.connection == connection {
                        pendingBrowserLogins.removeValue(forKey: loginId)
                        pending.timeoutTask.cancel()
                        pending.server.stop()
                        if pendingLoginIds[connection] == loginId {
                            pendingLoginIds.removeValue(forKey: connection)
                        }
                        await auth.loginCancel()
                        canceled = true
                        canceledBrowser = true
                    } else if let loginId,
                              pendingLoginIds[connection] == loginId {
                        await auth.loginCancel()
                        pendingLoginIds.removeValue(forKey: connection)
                        canceled = true
                    }
                    await reply(conn, id, .object([
                        "status": .string(canceled ? "canceled" : "notFound")]))
                    if canceled, let loginId {
                        // Upstream emits AccountLoginCompletedNotification on a
                        // cancelled login. Device-code cancellation carries the
                        // bare "Login was not completed" (account_processor.rs:466-468),
                        // while a cancelled BROWSER login surfaces the login-server
                        // io::Error ("Login was not completed", login/server.rs:195-196)
                        // wrapped by the browser background task as
                        // "Login server error: {err}" (account_processor.rs:397-398).
                        // The cancel *response* status remains "canceled" /
                        // "notFound" (above); only this notification carries the text.
                        let completionError = canceledBrowser
                            ? "Login server error: Login was not completed"
                            : "Login was not completed"
                        await conn.send(ServerNotification.accountLoginCompleted(
                            loginId: loginId, success: false,
                            error: completionError).toMessage())
                    }
                    return
                case "account/logout":
                    try? await auth.logout()
                    await reply(conn, id, .object([:]))
                    await conn.send(ServerNotification.accountUpdated(
                        authMode: nil, planType: nil).toMessage())
                    return
                default:
                    break
                }
            }
            await reply(conn, id, GenericResponses.defaultResult(for: method))

        // MARK: not a Codex method at all
        case .unsupported(let id, let method):
            // Upstream deserializes JSONRPCRequest into the ClientRequest enum;
            // an unrecognized method tag fails deserialization and is mapped to
            // `invalid_request(format!("Invalid request: {err}"))` => -32600
            // (app-server/src/message_processor.rs:536-541). The dispatch match
            // is exhaustive with no catch-all, so unknown methods never reach a
            // -32601 path. Mirror that here (NOT WireError.unsupported/-32601).
            await conn.send(WireError.invalidRequest(
                id: id, "Invalid request: unknown method `\(method)`"))
        }
    }

    private static func turnJSON(_ t: ReconstructedTurn) -> JSONValue {
        let items = t.items.compactMap { try? JSONBridge.value($0) }
        let status: String
        switch t.status {
        case .inProgress: status = "inProgress"
        case .completed: status = "completed"
        case .interrupted: status = "interrupted"
        case .failed: status = "failed"
        }
        return .object([
            "id": .string(t.id.raw),
            "items": .array(items),
            "itemsView": .string("full"),
            "status": .string(status),
            "error": .null,
            "startedAt": .null,
            "completedAt": .null,
            "durationMs": .null,
        ])
    }

    private func threadSessionResponse(thread: ThreadSummary,
                                       cfg: SessionConfig) -> ThreadSessionResponseEnvelope {
        let policy = SandboxPolicy.from(mode: cfg.sandboxMode,
                                        writableRoots: cfg.writableRoots,
                                        networkAccess: cfg.networkAccess)
        return ThreadSessionResponseEnvelope(
            thread: ThreadSummary(
                id: thread.id,
                preview: thread.preview,
                modelProvider: thread.modelProvider,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt,
                ephemeral: thread.ephemeral,
                name: thread.name,
                cwd: cfg.cwd,
                sessionId: thread.sessionId,
                cliVersion: thread.cliVersion,
                source: thread.source,
                status: thread.status,
                turns: thread.turns,
                gitInfo: thread.gitInfo),
            cwd: cfg.cwd,
            model: cfg.model,
            modelProvider: thread.modelProvider,
            approvalPolicy: .string(cfg.approvalPolicy.wireValue),
            approvalsReviewer: cfg.approvalsReviewer,
            sandbox: policy.toJSONValue(),
            serviceTier: nil)
    }

    private static func approvalPolicy(from value: JSONValue?,
                                       default fallback: ApprovalPolicy = .default)
        -> ApprovalPolicy {
        if let raw = value?.stringValue {
            return ApprovalPolicy(fromOptional: raw)
        }
        if let raw = value?["type"]?.stringValue ?? value?["mode"]?.stringValue {
            return ApprovalPolicy(fromOptional: raw)
        }
        return fallback
    }

    private static func notifyArgv(from config: Config?) -> [String]? {
        guard case .array(let values)? = config?.value("notify") else { return nil }
        let argv = values.compactMap(\.stringValue)
        return argv.isEmpty ? nil : argv
    }

    /// Resolved AGENTS.md knobs for a new (or resumed) thread, mirroring
    /// upstream's `Config.user_instructions` (loaded from the global
    /// `~/.codex/AGENTS.override.md` / `AGENTS.md`) plus the
    /// `project_doc_fallback_filenames` / `project_root_markers` /
    /// `project_doc_max_bytes` config knobs and the `ChildAgentsMd` feature.
    struct AgentsMdConfig {
        var userInstructions: String?
        var filenames: [String]
        var projectRootMarkers: [String]?
        var childEnabled: Bool
        var projectDocMaxBytes: Int
    }

    /// prompts finding A/B/C: gather the AGENTS.md inputs from live config so
    /// `thread/start` seeds the model-visible user-instructions section with
    /// the global instructions and honours the configured discovery knobs.
    /// Upstream loads global instructions via
    /// `AgentsMdManager::load_global_instructions(codex_home)`
    /// (`core/src/config/mod.rs:2349`) and reads the fallback filenames / root
    /// markers / `project_doc_max_bytes` from the merged config. A
    /// A `project_doc_max_bytes` of 0 disables *discovered project AGENTS.md
    /// docs* (`read_agents_md` short-circuit, `agents_md.rs:150-154`), but the
    /// GLOBAL override (`~/.codex/AGENTS.override.md` / `AGENTS.md`) is loaded
    /// UNCONDITIONALLY into `Config.user_instructions` (`config/mod.rs:2349`)
    /// and prepended every turn regardless of the budget
    /// (`user_instructions_with_fs`, `agents_md.rs:98-100`). So we always load
    /// the global override here; the zero-budget gate only affects the project
    /// docs (honoured downstream via `projectDocMaxBytes`).
    static func agentsMdConfig(_ config: Config, codexHome: String, cwd: String)
    -> AgentsMdConfig {
        let maxBytes = Int(config.projectDocMaxBytes)
        let markers = config.projectRootMarkers
        let filenames = config.projectDocFallbackFilenames
        let childEnabled = config.isFeatureEnabled("child_agents_md")
        let userInstructions = AgentsMdManager(
            codexHome: codexHome, cwd: cwd,
            projectDocMaxBytes: maxBytes,
            projectRootMarkers: markers ?? AgentsMdManager.DEFAULT_PROJECT_ROOT_MARKERS,
            fallbackFilenames: filenames,
            childAgentsMdEnabled: childEnabled
        ).loadGlobalInstructions()?.contents
        return AgentsMdConfig(
            userInstructions: userInstructions,
            filenames: filenames,
            projectRootMarkers: markers,
            childEnabled: childEnabled,
            projectDocMaxBytes: maxBytes)
    }

    /// Resolve the sandbox mode for a new thread. Priority:
    ///   1) explicit `p.sandbox` in `thread/start` params,
    ///   2) `sandbox_mode` from the loaded `config.toml`,
    ///   3) `.workspaceWrite` (built-in fallback).
    ///
    /// Without step (2), a client driving `thread/start` over the JSON-RPC
    /// protocol without passing `sandbox` would silently fall back to
    /// `workspaceWrite` even when `~/.codex/config.toml` set
    /// `sandbox_mode = "danger-full-access"`. Fixes F01 in the parity audit.
    private static func sandboxMode(from value: String?,
                                    fallbackConfig: Config?) -> SandboxModeKind {
        if let raw = value, !raw.isEmpty {
            return SandboxModeKind(fromOptional: raw)
        }
        if let raw = fallbackConfig?.sandboxMode {
            return SandboxModeKind(fromOptional: raw)
        }
        return .workspaceWrite
    }

    /// Resolve the default approval policy from the loaded config when the
    /// client did not pass `approvalPolicy` in `thread/start` params. Fixes
    /// the propagation half of F03 in the parity audit.
    private static func approvalPolicyFallback(from config: Config?) -> ApprovalPolicy {
        if let raw = config?.value("approval_policy")?.stringValue {
            return ApprovalPolicy(fromOptional: raw)
        }
        // Effective runtime default when neither the request nor the config
        // sets an approval policy. `on-request` is the port's intended default
        // (previously supplied via a synthetic `defaults()` entry, now applied
        // here so `config/read` can leave the field absent like upstream).
        return .onRequest
    }

    private struct RealtimeSessionState {
        var sessionId: String
        var outputModality: String
        var voice: String?
        var transportType: String
        var prompt: String?
        var appendedText: [String] = []
        var appendedAudioCount: Int = 0
    }

    private static let realtimeVoicesV1 = [
        "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse",
    ]
    private static let realtimeVoicesV2 = [
        "alloy", "arbor", "ash", "ballad", "breeze", "cedar", "coral", "cove",
        "echo", "ember", "juniper", "maple", "marin", "sage", "shimmer", "sol",
        "spruce", "vale", "verse",
    ]

    private func handleRealtimeRequest(id: RequestId, method: String,
                                       params: JSONValue?,
                                       conn: any ClientConnection) async -> Bool {
        // When a live backend is injected (codexd `CODEXKIT_REALTIME_LIVE=1`),
        // bridge to the OpenAI Realtime API instead of the echo mock. listVoices
        // stays the static catalog for both backends.
        if realtimeBackendFactory != nil, method != "thread/realtime/listVoices" {
            return await handleLiveRealtimeRequest(id: id, method: method,
                                                   params: params, conn: conn)
        }
        switch method {
        case "thread/realtime/listVoices":
            await reply(conn, id, Self.realtimeVoicesResponse())
            return true
        case "thread/realtime/start":
            do {
                let (threadId, state, sdpAnswer) = try Self.parseRealtimeStart(params: params)
                realtimeSessions[threadId] = state
                await reply(conn, id, .object([:]))
                await conn.send(ServerNotification.raw(
                    method: "thread/realtime/started",
                    params: .object([
                        "threadId": .string(threadId.raw),
                        "realtimeSessionId": .string(state.sessionId),
                        "version": .string("v2"),
                    ])).toMessage())
                if let sdpAnswer {
                    await conn.send(ServerNotification.raw(
                        method: "thread/realtime/sdp",
                        params: .object([
                            "threadId": .string(threadId.raw),
                            "sdp": .string(sdpAnswer),
                        ])).toMessage())
                }
                if let prompt = state.prompt, !prompt.isEmpty {
                    await conn.send(ServerNotification.raw(
                        method: "thread/realtime/itemAdded",
                        params: .object([
                            "threadId": .string(threadId.raw),
                            "item": .object([
                                "type": .string("message"),
                                "role": .string("system"),
                                "text": .string(prompt),
                            ]),
                        ])).toMessage())
                }
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        case "thread/realtime/appendText":
            do {
                let (threadId, text) = try Self.parseRealtimeAppendText(params: params)
                guard var state = realtimeSessions[threadId] else {
                    throw SimpleError("thread/realtime/appendText requires an active realtime session")
                }
                state.appendedText.append(text)
                realtimeSessions[threadId] = state
                await reply(conn, id, .object([:]))
                await conn.send(ServerNotification.raw(
                    method: "thread/realtime/transcript/delta",
                    params: .object([
                        "threadId": .string(threadId.raw),
                        "role": .string("user"),
                        "delta": .string(text),
                    ])).toMessage())
                await conn.send(ServerNotification.raw(
                    method: "thread/realtime/transcript/done",
                    params: .object([
                        "threadId": .string(threadId.raw),
                        "role": .string("user"),
                        "text": .string(text),
                    ])).toMessage())
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        case "thread/realtime/appendAudio":
            do {
                let (threadId, audio) = try Self.parseRealtimeAppendAudio(params: params)
                guard var state = realtimeSessions[threadId] else {
                    throw SimpleError("thread/realtime/appendAudio requires an active realtime session")
                }
                state.appendedAudioCount += 1
                realtimeSessions[threadId] = state
                await reply(conn, id, .object([:]))
                await conn.send(ServerNotification.raw(
                    method: "thread/realtime/outputAudio/delta",
                    params: .object([
                        "threadId": .string(threadId.raw),
                        "audio": audio,
                    ])).toMessage())
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        case "thread/realtime/stop":
            do {
                let threadId = try Self.parseRealtimeThreadId(params: params,
                                                              method: "thread/realtime/stop")
                guard realtimeSessions.removeValue(forKey: threadId) != nil else {
                    throw SimpleError("thread/realtime/stop requires an active realtime session")
                }
                await reply(conn, id, .object([:]))
                await conn.send(ServerNotification.raw(
                    method: "thread/realtime/closed",
                    params: .object([
                        "threadId": .string(threadId.raw),
                        "reason": .string("client_stopped"),
                    ])).toMessage())
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        default:
            return false
        }
    }

    private static func realtimeVoicesResponse() -> JSONValue {
        .object(["voices": .object([
            "v1": .array(realtimeVoicesV1.map(JSONValue.string)),
            "v2": .array(realtimeVoicesV2.map(JSONValue.string)),
            "defaultV1": .string("alloy"),
            "defaultV2": .string("marin"),
        ])])
    }

    /// Build the `thread/realtime/*` notification sink for a connection. Each
    /// `(method, params)` the live backend produces is wrapped in a
    /// `ServerNotification` and sent down `conn`.
    private static func makeRealtimeEmit(conn: any ClientConnection) -> RealtimeEmit {
        { method, params in
            await conn.send(ServerNotification.raw(method: method, params: params).toMessage())
        }
    }

    /// Live realtime backend dispatch (OpenAI Realtime API bridge). Mirrors the
    /// echo handler's start/itemAdded handshake, then hands the streaming
    /// transcript + audio to the injected backend session.
    private func handleLiveRealtimeRequest(id: RequestId, method: String,
                                           params: JSONValue?,
                                           conn: any ClientConnection) async -> Bool {
        guard let factory = realtimeBackendFactory else { return false }
        switch method {
        case "thread/realtime/start":
            do {
                let (threadId, state, sdpAnswer) = try Self.parseRealtimeStart(params: params)
                // Replace any prior live session on this thread.
                if let prior = liveRealtimeSessions.removeValue(forKey: threadId) {
                    await prior.stop(reason: "restart")
                }
                await reply(conn, id, .object([:]))
                await conn.send(ServerNotification.raw(
                    method: "thread/realtime/started",
                    params: .object([
                        "threadId": .string(threadId.raw),
                        "realtimeSessionId": .string(state.sessionId),
                        "version": .string("v2"),
                    ])).toMessage())
                if let sdpAnswer {
                    await conn.send(ServerNotification.raw(
                        method: "thread/realtime/sdp",
                        params: .object([
                            "threadId": .string(threadId.raw),
                            "sdp": .string(sdpAnswer),
                        ])).toMessage())
                }
                if let prompt = state.prompt, !prompt.isEmpty {
                    await conn.send(ServerNotification.raw(
                        method: "thread/realtime/itemAdded",
                        params: .object([
                            "threadId": .string(threadId.raw),
                            "item": .object([
                                "type": .string("message"),
                                "role": .string("system"),
                                "text": .string(prompt),
                            ]),
                        ])).toMessage())
                }
                let emit = Self.makeRealtimeEmit(conn: conn)
                let startParams = RealtimeStartParams(
                    threadId: threadId.raw,
                    outputModality: state.outputModality,
                    voice: state.voice,
                    instructions: state.prompt)
                do {
                    let session = try await factory(startParams, emit)
                    liveRealtimeSessions[threadId] = session
                } catch {
                    // Connection failed after we acknowledged start: tell the
                    // client the session closed rather than leaving it hanging.
                    await emit("thread/realtime/closed", .object([
                        "threadId": .string(threadId.raw),
                        "reason": .string("connect failed: \(error.localizedDescription)"),
                    ]))
                }
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        case "thread/realtime/appendText":
            do {
                let (threadId, text) = try Self.parseRealtimeAppendText(params: params)
                guard let session = liveRealtimeSessions[threadId] else {
                    throw SimpleError("thread/realtime/appendText requires an active realtime session")
                }
                await reply(conn, id, .object([:]))
                await session.appendText(text)
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        case "thread/realtime/appendAudio":
            do {
                let (threadId, audio) = try Self.parseRealtimeAppendAudio(params: params)
                guard let session = liveRealtimeSessions[threadId] else {
                    throw SimpleError("thread/realtime/appendAudio requires an active realtime session")
                }
                await reply(conn, id, .object([:]))
                await session.appendAudio(audio)
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        case "thread/realtime/stop":
            do {
                let threadId = try Self.parseRealtimeThreadId(params: params,
                                                              method: "thread/realtime/stop")
                guard let session = liveRealtimeSessions.removeValue(forKey: threadId) else {
                    throw SimpleError("thread/realtime/stop requires an active realtime session")
                }
                await reply(conn, id, .object([:]))
                // The session emits `thread/realtime/closed` itself.
                await session.stop(reason: "client_stopped")
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true
        default:
            return false
        }
    }

    private static func parseRealtimeStart(params: JSONValue?) throws
        -> (ThreadId, RealtimeSessionState, String?) {
        guard let params else { throw SimpleError("thread/realtime/start requires params") }
        let threadId = try parseRealtimeThreadId(params: params, method: "thread/realtime/start")
        let modality = params["outputModality"]?.stringValue ?? "text"
        guard modality == "text" || modality == "audio" else {
            throw SimpleError("thread/realtime/start outputModality must be text or audio")
        }
        let voice = params["voice"]?.stringValue
        if let voice, !realtimeVoicesV2.contains(voice) {
            throw SimpleError("thread/realtime/start voice is not supported")
        }
        // Realtime prompt selection (parity with upstream
        // `prepare_realtime_backend_prompt`, core/src/realtime_prompt.rs). Model
        // the request `prompt` as upstream `Option<Option<String>>`:
        //   - key absent              → `nil`          → default backend prompt
        //   - explicit `prompt: null` → `.some(.none)` → "" (no system prompt)
        //   - `prompt: "..."`         → `.some(.some)` → verbatim
        let requestPrompt: String??
        if params["prompt"] == nil {
            requestPrompt = nil
        } else if params["prompt"]?.isNull == true {
            requestPrompt = .some(.none)
        } else {
            requestPrompt = .some(params["prompt"]?.stringValue)
        }
        let resolvedPrompt = Templates.prepareRealtimeBackendPrompt(
            requestPrompt: requestPrompt,
            configPrompt: nil,
            userFirstName: Self.currentUserFirstName())
        // Empty resolved prompt → no system item is injected (matches the
        // existing `!prompt.isEmpty` gate downstream and upstream's empty-string
        // result for `Some(None)`).
        let prompt: String? = resolvedPrompt.isEmpty ? nil : resolvedPrompt
        let sessionId = params["realtimeSessionId"]?.stringValue
            ?? "rt_\(threadId.raw)_\(UUID().uuidString)"
        let transport = params["transport"]?.objectValue ?? ["type": .string("websocket")]
        let transportType = transport["type"]?.stringValue ?? "websocket"
        let sdpAnswer: String?
        switch transportType {
        case "websocket":
            sdpAnswer = nil
        case "webrtc":
            guard let offer = transport["sdp"]?.stringValue, !offer.isEmpty else {
                throw SimpleError("thread/realtime/start WebRTC transport requires sdp")
            }
            sdpAnswer = Self.mockWebRTCAnswer(for: offer)
        default:
            throw SimpleError("thread/realtime/start transport type must be websocket or webrtc")
        }
        let state = RealtimeSessionState(sessionId: sessionId, outputModality: modality,
                                         voice: voice, transportType: transportType,
                                         prompt: prompt)
        return (threadId, state, sdpAnswer)
    }

    private static func parseRealtimeAppendText(params: JSONValue?) throws -> (ThreadId, String) {
        guard let params else { throw SimpleError("thread/realtime/appendText requires params") }
        let threadId = try parseRealtimeThreadId(params: params, method: "thread/realtime/appendText")
        guard let text = params["text"]?.stringValue else {
            throw SimpleError("thread/realtime/appendText requires text")
        }
        return (threadId, text)
    }

    private static func parseRealtimeAppendAudio(params: JSONValue?) throws -> (ThreadId, JSONValue) {
        guard let params else { throw SimpleError("thread/realtime/appendAudio requires params") }
        let threadId = try parseRealtimeThreadId(params: params, method: "thread/realtime/appendAudio")
        guard let audio = params["audio"], let object = audio.objectValue else {
            throw SimpleError("thread/realtime/appendAudio requires audio")
        }
        guard object["data"]?.stringValue != nil,
              object["sampleRate"]?.intValue != nil,
              object["numChannels"]?.intValue != nil else {
            throw SimpleError("thread/realtime/appendAudio audio requires data, sampleRate, and numChannels")
        }
        return (threadId, audio)
    }

    private static func parseRealtimeThreadId(params: JSONValue?, method: String) throws -> ThreadId {
        guard let raw = params?["threadId"]?.stringValue,
              ThreadId(raw).isWellFormed else {
            throw SimpleError("\(method) requires valid threadId")
        }
        return ThreadId(raw)
    }

    private static func mockWebRTCAnswer(for offer: String) -> String {
        let offerHash = abs(offer.hashValue)
        return """
        v=0
        o=codexkit \(offerHash) 0 IN IP4 127.0.0.1
        s=CodexKit Realtime
        t=0 0
        a=group:BUNDLE 0
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sctp-port:5000
        a=setup:active
        """
    }

    private func handleThreadMetadataRequest(id: RequestId, method: String,
                                             params: JSONValue?,
                                             conn: any ClientConnection) async -> Bool {
        guard method == "thread/metadata/update" else { return false }
        guard let threadIdRaw = params?["threadId"]?.stringValue else {
            await conn.send(WireError.invalidRequest(id: id, "missing threadId"))
            return true
        }
        let threadId = ThreadId(threadIdRaw)
        guard threadId.isWellFormed else {
            await conn.send(WireError.invalidRequest(id: id, "invalid threadId"))
            return true
        }
        guard let obj = params?.objectValue, obj.keys.contains("gitInfo") else {
            await conn.send(WireError.invalidRequest(
                id: id, "thread/metadata/update requires gitInfo patch"))
            return true
        }
        let current = (try? await store.gitInfo(threadId)) ?? ThreadStore.GitInfoState()
        let next: ThreadStore.GitInfoState?
        if params?["gitInfo"]?.isNull == true {
            next = nil
        } else if let patch = params?["gitInfo"]?.objectValue {
            var info = current
            if patch.keys.contains("sha") { info.sha = patch["sha"]?.stringValue }
            if patch.keys.contains("branch") { info.branch = patch["branch"]?.stringValue }
            if patch.keys.contains("originUrl") { info.originURL = patch["originUrl"]?.stringValue }
            if info.isEmpty {
                next = nil
            } else {
                next = info
            }
        } else {
            await conn.send(WireError.invalidRequest(
                id: id, "thread/metadata/update gitInfo must be object or null"))
            return true
        }
        do {
            try await store.setGitInfo(threadId, next)
            let rebuilt = try? await store.reconstruct(threadId)
            var summary = ThreadSummary(
                id: threadId,
                createdAt: Int64(Date().timeIntervalSince1970),
                ephemeral: rebuilt?.config.ephemeral ?? false,
                cwd: rebuilt?.config.cwd ?? FileManager.default.currentDirectoryPath,
                gitInfo: next?.json)
            summary.name = try? await store.name(threadId)
            await reply(conn, id, ThreadResultEnvelope(thread: summary))
        } catch {
            await conn.send(WireError.internalError(id: id, error.localizedDescription))
        }
        return true
    }

    private func handleThreadElicitationRequest(id: RequestId, method: String,
                                                params: JSONValue?,
                                                conn: any ClientConnection) async -> Bool {
        guard method == "thread/increment_elicitation"
                || method == "thread/decrement_elicitation" else {
            return false
        }
        guard let rawThreadId = params?["threadId"]?.stringValue else {
            await conn.send(WireError.invalidRequest(id: id, "\(method) requires threadId"))
            return true
        }
        let threadId = ThreadId(rawThreadId)
        guard threadId.isWellFormed else {
            await conn.send(WireError.invalidRequest(id: id, "invalid threadId"))
            return true
        }
        guard await threadExists(threadId) else {
            await conn.send(WireError.invalidRequest(
                id: id, "\(method) thread not found: \(threadId.raw)"))
            return true
        }

        switch method {
        case "thread/increment_elicitation":
            let current = outOfBandElicitationCounts[threadId] ?? 0
            guard current < Int64.max else {
                await conn.send(WireError.internalError(
                    id: id, "out-of-band elicitation count overflowed"))
                return true
            }
            let next = current + 1
            outOfBandElicitationCounts[threadId] = next
            await reply(conn, id, .object([
                "count": .int(next),
                "paused": .bool(next > 0),
            ]))
        case "thread/decrement_elicitation":
            let current = outOfBandElicitationCounts[threadId] ?? 0
            guard current > 0 else {
                await conn.send(WireError.invalidRequest(
                    id: id, "out-of-band elicitation count is already zero"))
                return true
            }
            let next = current - 1
            if next == 0 {
                outOfBandElicitationCounts.removeValue(forKey: threadId)
            } else {
                outOfBandElicitationCounts[threadId] = next
            }
            await reply(conn, id, .object([
                "count": .int(next),
                "paused": .bool(next > 0),
            ]))
        default:
            return false
        }
        return true
    }

    private func handleThreadBackgroundTerminalsCleanRequest(
        id: RequestId,
        method: String,
        params: JSONValue?,
        conn: any ClientConnection
    ) async -> Bool {
        guard method == "thread/backgroundTerminals/clean" else { return false }
        guard let rawThreadId = params?["threadId"]?.stringValue else {
            await conn.send(WireError.invalidRequest(
                id: id, "thread/backgroundTerminals/clean requires threadId"))
            return true
        }
        let threadId = ThreadId(rawThreadId)
        guard threadId.isWellFormed else {
            await conn.send(WireError.invalidRequest(id: id, "invalid threadId"))
            return true
        }
        guard await threadExists(threadId) else {
            await conn.send(WireError.invalidRequest(
                id: id, "thread/backgroundTerminals/clean thread not found: \(threadId.raw)"))
            return true
        }

        // Swift does not currently keep Rust-style unified-exec background
        // terminals in the session worker. Once that subsystem exists, this is
        // the app-server validation boundary that should route the clean op.
        await reply(conn, id, EmptyResponse())
        return true
    }

    private func threadExists(_ threadId: ThreadId) async -> Bool {
        if await supervisor.isBound(threadId) { return true }
        if await store.loadedList().contains(threadId.raw) { return true }
        if ((try? await store.list(archived: false, limit: 10_000)) ?? [])
            .contains(where: { $0.id == threadId }) {
            return true
        }
        if ((try? await store.list(archived: true, limit: 10_000)) ?? [])
            .contains(where: { $0.id == threadId }) {
            return true
        }
        return false
    }

    private func handleConversationSummaryRequest(id: RequestId, method: String,
                                                  params: JSONValue?,
                                                  conn: any ClientConnection) async -> Bool {
        guard method == "getConversationSummary" else { return false }
        do {
            let summary: ConversationSummaryState?
            let missingDescription: String
            if let rolloutPath = params?["rolloutPath"]?.stringValue {
                summary = try await store.conversationSummary(rolloutPath: rolloutPath)
                missingDescription = "rollout path \(rolloutPath)"
            } else if let conversationId = params?["conversationId"]?.stringValue {
                let threadId = ThreadId(conversationId)
                guard threadId.isWellFormed else {
                    await conn.send(WireError.invalidRequest(id: id, "invalid conversationId"))
                    return true
                }
                summary = try await store.conversationSummary(id: threadId)
                missingDescription = "conversation id \(conversationId)"
            } else {
                await conn.send(WireError.invalidRequest(
                    id: id, "getConversationSummary requires conversationId or rolloutPath"))
                return true
            }
            guard let summary else {
                await conn.send(WireError.invalidRequest(
                    id: id, "no rollout found for \(missingDescription)"))
                return true
            }
            await reply(conn, id, .object(["summary": Self.conversationSummaryJSON(summary)]))
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private func handleGitRequest(id: RequestId, method: String, params: JSONValue?,
                                  conn: any ClientConnection) async -> Bool {
        guard method == "gitDiffToRemote" else { return false }
        guard let cwd = params?["cwd"]?.stringValue, !cwd.isEmpty else {
            await conn.send(WireError.invalidRequest(id: id, "gitDiffToRemote requires cwd"))
            return true
        }
        guard let state = await GitUtils(cwd: cwd).diffToRemoteState() else {
            await conn.send(WireError.invalidRequest(
                id: id, "failed to compute git diff to remote for cwd: \(cwd)"))
            return true
        }
        await reply(conn, id, .object([
            "sha": .string(state.sha),
            "diff": .string(state.diff),
        ]))
        return true
    }

    private func handleGetAuthStatusRequest(id: RequestId, method: String, params: JSONValue?,
                                            conn: any ClientConnection) async -> Bool {
        guard method == "getAuthStatus" else { return false }
        let includeToken = params?["includeToken"]?.boolValue ?? false
        let refreshToken = params?["refreshToken"]?.boolValue ?? false
        // Mirror upstream get_auth_status_response (account_processor.rs:751-758):
        // when the active model provider does not require OpenAI auth, report
        // authMethod:nil / authToken:nil / requiresOpenaiAuth:false without
        // consulting the token store, matching account/read (getAccountResponse).
        guard currentProviderRequiresOpenAIAuth() else {
            await reply(conn, id, Self.authStatusJSON(
                authMethod: nil, authToken: nil, requiresOpenaiAuth: false))
            return true
        }
        guard let auth else {
            await reply(conn, id, Self.authStatusJSON(
                authMethod: nil, authToken: nil, requiresOpenaiAuth: true))
            return true
        }

        guard let initialTokens = await auth.storedTokens() else {
            await reply(conn, id, Self.authStatusJSON(
                authMethod: nil, authToken: nil, requiresOpenaiAuth: true))
            return true
        }

        if refreshToken,
           initialTokens.refreshToken != nil,
           initialTokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame {
            _ = await auth.refreshAccessToken()
        }

        guard let tokens = await auth.storedTokens(),
              let authMethod = Self.authMethod(for: tokens) else {
            await reply(conn, id, Self.authStatusJSON(
                authMethod: nil, authToken: nil, requiresOpenaiAuth: true))
            return true
        }

        // Mirror upstream's `get_token()` branch
        // (account_processor.rs:776-787): an empty access token is treated as
        // the no-token state (authMethod:nil), not a present-token state. This
        // distinguishes a degenerate empty-token credential from a real one.
        guard !tokens.accessToken.isEmpty else {
            await reply(conn, id, Self.authStatusJSON(
                authMethod: nil, authToken: nil, requiresOpenaiAuth: true))
            return true
        }

        let hasRefreshFailure = await auth.hasRefreshFailure(for: tokens)
        let token = includeToken && !hasRefreshFailure ? tokens.accessToken : nil
        await reply(conn, id, Self.authStatusJSON(
            authMethod: authMethod, authToken: token, requiresOpenaiAuth: true))
        return true
    }

    private func handleSendAddCreditsNudgeEmailRequest(id: RequestId, method: String,
                                                       params: JSONValue?,
                                                       conn: any ClientConnection) async -> Bool {
        guard method == "account/sendAddCreditsNudgeEmail" else { return false }
        guard let auth else {
            await conn.send(WireError.invalidRequest(
                id: id, "codex account authentication required to notify workspace owner"))
            return true
        }
        guard let tokens = await auth.storedTokens() else {
            await conn.send(WireError.invalidRequest(
                id: id, "codex account authentication required to notify workspace owner"))
            return true
        }
        guard tokens.tokenType != "APIKey" else {
            await conn.send(WireError.invalidRequest(
                id: id, "chatgpt authentication required to notify workspace owner"))
            return true
        }
        guard let creditType = params?["creditType"]?.stringValue else {
            await conn.send(WireError.invalidRequest(
                id: id, "account/sendAddCreditsNudgeEmail requires creditType"))
            return true
        }
        guard creditType == "credits" || creditType == "usage_limit" else {
            await conn.send(WireError.invalidRequest(
                id: id, "account/sendAddCreditsNudgeEmail creditType must be credits or usage_limit"))
            return true
        }
        do {
            let status = try await accountNudgeEmailSender(
                tokens, Self.chatGPTBaseURL(codexHome: codexHome), creditType)
            await reply(conn, id, .object(["status": .string(status)]))
        } catch let status as AccountNudgeEmailHTTPStatusError where status.statusCode == 429 {
            await reply(conn, id, .object(["status": .string("cooldown_active")]))
        } catch {
            await conn.send(WireError.internalError(
                id: id, "failed to notify workspace owner: \(error.localizedDescription)"))
        }
        return true
    }

    private func handleRemoteControlRequest(id: RequestId, method: String,
                                            params: JSONValue?,
                                            conn: any ClientConnection) async -> Bool {
        switch method {
        case "remoteControl/status/read":
            do {
                await reply(conn, id, try remoteControlResponse())
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to read remote-control status: \(error.localizedDescription)"))
            }
            return true
        case "remoteControl/disable":
            do {
                remoteControlGeneration &+= 1
                remoteControlReconnectRequest = nil
                if let connection = remoteControlWebSocketConnection {
                    remoteControlWebSocketConnection = nil
                    await connection.close()
                }
                await closeRemoteControlVirtualClients()
                let changed = try setRemoteControlStatus("disabled", environmentId: nil)
                let response = try remoteControlResponse()
                await reply(conn, id, response)
                if changed {
                    await sendRemoteControlStatusChanged(response, conn: conn)
                }
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to disable remote control: \(error.localizedDescription)"))
            }
            return true
        case "remoteControl/enable":
            guard let auth else {
                await conn.send(WireError.invalidRequest(
                    id: id, "codex account authentication required to enable remote control"))
                return true
            }
            guard let tokens = await auth.storedTokens() else {
                await conn.send(WireError.invalidRequest(
                    id: id, "codex account authentication required to enable remote control"))
                return true
            }
            guard tokens.tokenType != "APIKey" else {
                await conn.send(WireError.invalidRequest(
                    id: id, "chatgpt authentication required to enable remote control"))
                return true
            }
            do {
                remoteControlGeneration &+= 1
                remoteControlReconnectRequest = nil
                let generation = remoteControlGeneration
                if let connection = remoteControlWebSocketConnection {
                    remoteControlWebSocketConnection = nil
                    await connection.close()
                }
                let changed = try setRemoteControlStatus("connecting", environmentId: nil)
                let response = try remoteControlResponse()
                let state = try currentRemoteControlState()
                let baseURL = Self.chatGPTBaseURL(codexHome: codexHome)
                let enroller = remoteControlEnroller
                let connector = remoteControlWebSocketConnector
                await reply(conn, id, response)
                if changed {
                    await sendRemoteControlStatusChanged(response, conn: conn)
                }
                Task { [tokens, baseURL, enroller, connector, state, generation, conn] in
                    do {
                        let enrollment = try await enroller(
                            tokens, baseURL, state.installationId, state.serverName)
                        await self.remoteControlEnrollmentSucceeded(
                            enrollment,
                            tokens: tokens,
                            baseURL: baseURL,
                            connector: connector,
                            generation: generation,
                            conn: conn)
                    } catch {
                        await self.remoteControlEnrollmentFailed(
                            generation: generation,
                            conn: conn)
                    }
                }
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to enable remote control: \(error.localizedDescription)"))
            }
            return true
        default:
            return false
        }
    }

    private func handleEnvironmentRequest(id: RequestId, method: String,
                                          params: JSONValue?,
                                          conn: any ClientConnection) async -> Bool {
        guard method == "environment/add" else { return false }
        do {
            let environmentId = try Self.requiredEnvironmentString(
                params?["environmentId"], field: "environmentId")
            let execServerURL = try Self.requiredEnvironmentString(
                params?["execServerUrl"], field: "execServerUrl")
            try Self.validateRemoteEnvironmentId(environmentId)
            try Self.validateExecServerURL(execServerURL)
            remoteEnvironments[environmentId] = execServerURL
            await reply(conn, id, .object([:]))
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private func validateRemoteEnvironmentSelection(
        id: RequestId,
        method: String,
        params: JSONValue?,
        conn: any ClientConnection
    ) async -> Bool {
        guard method == "thread/start" || method == "turn/start" else { return false }
        guard let environments = params?["environments"]?.arrayValue else { return false }
        var seen = Set<String>()
        for value in environments {
            guard let object = value.objectValue,
                  let environmentId = object["environmentId"]?.stringValue,
                  !environmentId.isEmpty else {
                await conn.send(WireError.invalidRequest(
                    id: id, "\(method).environments entries require environmentId"))
                return true
            }
            guard seen.insert(environmentId).inserted else {
                await conn.send(WireError.invalidRequest(
                    id: id,
                    "\(method).environments contains duplicate environmentId \(environmentId)"))
                return true
            }
            if let cwd = object["cwd"]?.stringValue, !cwd.hasPrefix("/") {
                await conn.send(WireError.invalidRequest(
                    id: id, "\(method).environments cwd must be absolute"))
                return true
            }
            if environmentId == "local" { continue }
            guard remoteEnvironments[environmentId] != nil else {
                await conn.send(WireError.invalidRequest(
                    id: id, "unknown environmentId \(environmentId)"))
                return true
            }
        }
        return false
    }

    private func selectedRemoteEnvironment(
        _ environments: [ThreadStartParams.EnvironmentParams]?
    ) -> SessionConfig.RemoteEnvironment? {
        guard let selected = environments?.first(where: { $0.environmentId != "local" }),
              let execServerUrl = remoteEnvironments[selected.environmentId] else {
            return nil
        }
        return .init(environmentId: selected.environmentId, execServerUrl: execServerUrl)
    }

    private func selectedRemoteEnvironment(
        _ environments: [TurnStartParams.EnvironmentParams]?
    ) -> SessionConfig.RemoteEnvironment? {
        guard let selected = environments?.first(where: { $0.environmentId != "local" }),
              let execServerUrl = remoteEnvironments[selected.environmentId] else {
            return nil
        }
        return .init(environmentId: selected.environmentId, execServerUrl: execServerUrl)
    }

    private static func requiredEnvironmentString(_ value: JSONValue?,
                                                  field: String) throws -> String {
        guard let string = value?.stringValue else {
            throw SimpleError("environment/add requires \(field)")
        }
        return string
    }

    private static func validateRemoteEnvironmentId(_ id: String) throws {
        guard !id.isEmpty else {
            throw SimpleError("environment id cannot be empty")
        }
        guard id.trimmingCharacters(in: .whitespacesAndNewlines) == id else {
            throw SimpleError("environment id `\(id)` must not contain surrounding whitespace")
        }
        guard id != "local", id.lowercased() != "none" else {
            throw SimpleError("environment id `\(id)` is reserved")
        }
        guard id.count <= 64 else {
            throw SimpleError("environment id `\(id)` cannot be longer than 64 characters")
        }
        guard id.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }) else {
            throw SimpleError(
                "environment id `\(id)` must contain only ASCII letters, numbers, '-' or '_'")
        }
    }

    private static func validateExecServerURL(_ raw: String) throws {
        guard !raw.isEmpty else {
            throw SimpleError("remote environment requires an exec-server url")
        }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            throw SimpleError(
                "environment/add execServerUrl must be an absolute http(s) or ws(s) URL")
        }
    }

    private func remoteControlEnrollmentSucceeded(
        _ enrollment: RemoteControlEnrollment,
        tokens: AuthTokens,
        baseURL: String,
        connector: RemoteControlWebSocketConnector,
        generation: UInt64,
        conn: any ClientConnection
    ) async {
        do {
            guard generation == remoteControlGeneration,
                  (try? currentRemoteControlState().status) != "disabled" else {
                return
            }
            let target = try Self.normalizedRemoteControlTarget(baseURL)
            let changed = try setRemoteControlStatus(
                "connecting",
                environmentId: enrollment.environmentId)
            if changed, let response = try? remoteControlResponse() {
                await sendRemoteControlStatusChanged(response, conn: conn)
            }
            let state = try currentRemoteControlState()
            let request = RemoteControlWebSocketRequest(
                websocketURL: target.websocketURL,
                accessToken: tokens.accessToken,
                accountId: tokens.accountId,
                serverId: enrollment.serverId,
                serverName: state.serverName,
                installationId: state.installationId)
            let connection = try await connector(request)
            guard generation == remoteControlGeneration,
                  (try? currentRemoteControlState().status) != "disabled" else {
                await connection.close()
                return
            }
            remoteControlReconnectRequest = request
            remoteControlWebSocketConnection = connection
            startRemoteControlBridge(connection, generation: generation, statusConn: conn)
            let connected = try setRemoteControlStatus(
                "connected",
                environmentId: enrollment.environmentId)
            if connected, let response = try? remoteControlResponse() {
                await sendRemoteControlStatusChanged(response, conn: conn)
            }
        } catch {
            await remoteControlEnrollmentFailed(generation: generation, conn: conn)
        }
    }

    private func startRemoteControlBridge(_ connection: RemoteControlWebSocketConnection,
                                          generation: UInt64,
                                          statusConn: any ClientConnection) {
        Task { [connection, generation] in
            await self.runRemoteControlIdleSweep(
                websocket: connection,
                generation: generation)
        }
        Task { [connection, generation] in
            await self.runRemoteControlWebSocketHeartbeat(
                websocket: connection,
                generation: generation)
        }
        Task { [connection, generation, statusConn] in
            for await envelope in connection.incoming {
                await self.handleRemoteControlClientEnvelope(
                    envelope,
                    websocket: connection,
                    generation: generation)
            }
            await self.remoteControlWebSocketDidClose(
                connection,
                generation: generation,
                statusConn: statusConn)
        }
    }

    private func runRemoteControlIdleSweep(
        websocket: RemoteControlWebSocketConnection,
        generation: UInt64
    ) async {
        while generation == remoteControlGeneration,
              remoteControlWebSocketConnection === websocket,
              (try? currentRemoteControlState().status) != "disabled" {
            try? await Task.sleep(
                for: .milliseconds(Self.remoteControlIdleSweepIntervalMilliseconds()))
            guard generation == remoteControlGeneration,
                  remoteControlWebSocketConnection === websocket else {
                return
            }
            await closeExpiredRemoteControlVirtualClients(now: Date())
        }
    }

    private func runRemoteControlWebSocketHeartbeat(
        websocket: RemoteControlWebSocketConnection,
        generation: UInt64
    ) async {
        while generation == remoteControlGeneration,
              remoteControlWebSocketConnection === websocket,
              (try? currentRemoteControlState().status) != "disabled" {
            try? await Task.sleep(
                for: .milliseconds(Self.remoteControlPingIntervalMilliseconds()))
            guard generation == remoteControlGeneration,
                  remoteControlWebSocketConnection === websocket else {
                return
            }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await websocket.ping() }
                    group.addTask {
                        try await Task.sleep(
                            for: .milliseconds(
                                Self.remoteControlPongTimeoutMilliseconds()))
                        throw SimpleError("remote control websocket pong timeout")
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                await websocket.close()
                return
            }
        }
    }

    private func remoteControlWebSocketDidClose(_ connection: RemoteControlWebSocketConnection,
                                                generation: UInt64,
                                                statusConn: any ClientConnection) async {
        guard generation == remoteControlGeneration,
              remoteControlWebSocketConnection === connection else {
            return
        }
        remoteControlWebSocketConnection = nil
        do {
            let changed = try setRemoteControlStatus("errored", environmentId: nil)
            if changed, let response = try? remoteControlResponse() {
                await sendRemoteControlStatusChanged(response, conn: statusConn)
            }
        } catch {}
        Task { [generation, statusConn] in
            await self.reconnectRemoteControlWebSocket(
                generation: generation,
                statusConn: statusConn)
        }
    }

    private func reconnectRemoteControlWebSocket(generation: UInt64,
                                                 statusConn: any ClientConnection) async {
        guard generation == remoteControlGeneration,
              (try? currentRemoteControlState().status) != "disabled",
              let request = remoteControlReconnectRequest else {
            return
        }
        do {
            let connection = try await remoteControlWebSocketConnector(request)
            guard generation == remoteControlGeneration,
                  (try? currentRemoteControlState().status) != "disabled",
                  remoteControlWebSocketConnection == nil else {
                await connection.close()
                return
            }
            remoteControlWebSocketConnection = connection
            for client in remoteControlVirtualClients.values {
                client.connection.updateWebSocket(connection)
            }
            startRemoteControlBridge(connection, generation: generation, statusConn: statusConn)
            for client in remoteControlVirtualClients.values {
                await client.connection.replayBufferedEnvelopes()
            }
            let environmentId = try currentRemoteControlState().environmentId
            let changed = try setRemoteControlStatus("connected", environmentId: environmentId)
            if changed, let response = try? remoteControlResponse() {
                await sendRemoteControlStatusChanged(response, conn: statusConn)
            }
        } catch {
            do {
                let changed = try setRemoteControlStatus("errored", environmentId: nil)
                if changed, let response = try? remoteControlResponse() {
                    await sendRemoteControlStatusChanged(response, conn: statusConn)
                }
            } catch {}
        }
    }

    private func handleRemoteControlClientEnvelope(
        _ incomingEnvelope: RemoteControlClientEnvelope,
        websocket: RemoteControlWebSocketConnection,
        generation: UInt64
    ) async {
        guard generation == remoteControlGeneration,
              remoteControlWebSocketConnection === websocket else {
            return
        }
        guard let envelope = observeRemoteControlClientEnvelope(incomingEnvelope) else {
            return
        }
        let streamId = remoteControlStreamId(for: envelope)
        let key = RemoteControlVirtualClientKey(
            clientId: envelope.clientId,
            streamId: streamId)
        switch envelope.event {
        case .ack(let segmentId):
            if let seqId = envelope.seqId,
               let client = remoteControlVirtualClients[key] {
                client.connection.ack(seqId: seqId, segmentId: segmentId)
            }
            return
        case .ping:
            let status = remoteControlVirtualClients[key] == nil ? "unknown" : "active"
            if var client = remoteControlVirtualClients[key] {
                client.lastActivityAt = Date()
                remoteControlVirtualClients[key] = client
            }
            let connection = remoteControlVirtualClients[key]?.connection
                ?? RemoteControlVirtualConnection(
                    clientId: envelope.clientId,
                    streamId: streamId,
                    websocket: websocket)
            await connection.sendPong(status: status)
        case .clientClosed:
            if let client = remoteControlVirtualClients.removeValue(forKey: key) {
                await client.router.connectionClosed(client.connection)
            }
            invalidateRemoteControlClientSegments(clientId: envelope.clientId,
                                                  streamId: envelope.streamId)
            if remoteControlLegacyStreamIds[envelope.clientId] == streamId {
                remoteControlLegacyStreamIds.removeValue(forKey: envelope.clientId)
            }
        case .clientMessage(let message):
            await handleRemoteControlClientMessage(
                message,
                envelope: envelope,
                streamId: streamId,
                key: key,
                websocket: websocket)
        case .clientMessageChunk:
            return
        }
    }

    private func observeRemoteControlClientEnvelope(
        _ envelope: RemoteControlClientEnvelope
    ) -> RemoteControlClientEnvelope? {
        if case .clientMessageChunk = envelope.event,
           let seqId = envelope.seqId {
            let key = RemoteControlClientChunkKey(
                clientId: envelope.clientId,
                streamId: envelope.streamId)
            if remoteControlLastCompletedClientChunkSeqIds[key]
                .map({ $0 >= seqId }) == true {
                return nil
            }
        }
        guard let observed = remoteControlClientSegmentReassembler.observe(envelope) else {
            return nil
        }
        if case .clientMessage = observed.event,
           case .clientMessageChunk = envelope.event,
           let seqId = observed.seqId {
            let key = RemoteControlClientChunkKey(
                clientId: observed.clientId,
                streamId: observed.streamId)
            remoteControlLastCompletedClientChunkSeqIds[key] = seqId
        }
        if let cursor = observed.cursor, !cursor.isEmpty {
            // Stored for future reconnect support; current request-level enable
            // establishes one websocket connection per enable generation.
            _ = cursor
        }
        return observed
    }

    private func invalidateRemoteControlClientSegments(clientId: String, streamId: String?) {
        if let streamId {
            remoteControlClientSegmentReassembler.invalidateStream(
                clientId: clientId,
                streamId: streamId)
            remoteControlLastCompletedClientChunkSeqIds.removeValue(
                forKey: RemoteControlClientChunkKey(clientId: clientId, streamId: streamId))
        } else {
            remoteControlClientSegmentReassembler.invalidateClient(clientId)
            remoteControlLastCompletedClientChunkSeqIds =
                remoteControlLastCompletedClientChunkSeqIds.filter { key, _ in
                    key.clientId != clientId
                }
        }
    }

    private func handleRemoteControlClientMessage(
        _ message: JSONRPCMessage,
        envelope: RemoteControlClientEnvelope,
        streamId: String,
        key: RemoteControlVirtualClientKey,
        websocket: RemoteControlWebSocketConnection
    ) async {
        let startsConnection = Self.remoteControlMessageStartsConnection(message)
        if var existing = remoteControlVirtualClients[key] {
            if let seqId = envelope.seqId,
               let last = existing.lastInboundSeqId,
               last >= seqId,
               !startsConnection {
                return
            }
            if startsConnection {
                await existing.router.connectionClosed(existing.connection)
                remoteControlVirtualClients.removeValue(forKey: key)
            } else {
                existing.lastActivityAt = Date()
                existing.lastInboundSeqId = envelope.seqId ?? existing.lastInboundSeqId
                remoteControlVirtualClients[key] = existing
                await existing.router.handle(message, existing.connection)
                return
            }
        }

        guard startsConnection else { return }
        let childRouter = RequestRouter(
            supervisor: supervisor,
            store: store,
            codexHome: codexHome,
            auth: auth,
            config: config,
            requirementsLoader: requirementsLoader,
            accountRateLimitsFetcher: accountRateLimitsFetcher,
            accountNudgeEmailSender: accountNudgeEmailSender,
            remoteControlEnroller: remoteControlEnroller,
            remoteControlWebSocketConnector: remoteControlWebSocketConnector,
            memoryResetHandler: memoryResetHandler,
            wikiQuery: wikiQuery)
        let connection = RemoteControlVirtualConnection(
            clientId: envelope.clientId,
            streamId: streamId,
            websocket: websocket)
        remoteControlVirtualClients[key] = RemoteControlVirtualClient(
            router: childRouter,
            connection: connection,
            lastInboundSeqId: envelope.seqId,
            lastActivityAt: Date())
        if envelope.streamId == nil {
            remoteControlLegacyStreamIds[envelope.clientId] = streamId
        }
        await childRouter.handle(message, connection)
    }

    private func remoteControlStreamId(for envelope: RemoteControlClientEnvelope) -> String {
        if let streamId = envelope.streamId, !streamId.isEmpty {
            return streamId
        }
        if let streamId = remoteControlLegacyStreamIds[envelope.clientId] {
            return streamId
        }
        return "legacy-\(envelope.clientId)"
    }

    private static func remoteControlMessageStartsConnection(_ message: JSONRPCMessage) -> Bool {
        if case .request(let request) = message {
            return request.method == "initialize"
        }
        return false
    }

    private static func remoteControlClientIdleTimeoutMilliseconds() -> UInt64 {
        remoteControlDurationMilliseconds(
            environmentKey: "CODEXKIT_REMOTE_CONTROL_CLIENT_IDLE_TIMEOUT_MS",
            defaultMilliseconds: 10 * 60 * 1000)
    }

    private static func remoteControlIdleSweepIntervalMilliseconds() -> UInt64 {
        remoteControlDurationMilliseconds(
            environmentKey: "CODEXKIT_REMOTE_CONTROL_IDLE_SWEEP_INTERVAL_MS",
            defaultMilliseconds: 30 * 1000)
    }

    private static func remoteControlPingIntervalMilliseconds() -> UInt64 {
        remoteControlDurationMilliseconds(
            environmentKey: "CODEXKIT_REMOTE_CONTROL_PING_INTERVAL_MS",
            defaultMilliseconds: 10 * 1000)
    }

    private static func remoteControlPongTimeoutMilliseconds() -> UInt64 {
        remoteControlDurationMilliseconds(
            environmentKey: "CODEXKIT_REMOTE_CONTROL_PONG_TIMEOUT_MS",
            defaultMilliseconds: 60 * 1000)
    }

    private static func remoteControlDurationMilliseconds(
        environmentKey: String,
        defaultMilliseconds: UInt64
    ) -> UInt64 {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              let value = UInt64(raw),
              value > 0 else {
            return defaultMilliseconds
        }
        return value
    }

    private func closeExpiredRemoteControlVirtualClients(now: Date) async {
        let timeoutSeconds =
            Double(Self.remoteControlClientIdleTimeoutMilliseconds()) / 1000.0
        let expiredKeys = remoteControlVirtualClients.compactMap { key, client in
            now.timeIntervalSince(client.lastActivityAt) >= timeoutSeconds ? key : nil
        }
        for key in expiredKeys {
            if let client = remoteControlVirtualClients.removeValue(forKey: key) {
                await client.router.connectionClosed(client.connection)
                invalidateRemoteControlClientSegments(
                    clientId: key.clientId,
                    streamId: key.streamId)
            }
            if remoteControlLegacyStreamIds[key.clientId] == key.streamId {
                remoteControlLegacyStreamIds.removeValue(forKey: key.clientId)
            }
        }
    }

    private func closeRemoteControlVirtualClients() async {
        let clients = remoteControlVirtualClients.values
        remoteControlVirtualClients.removeAll()
        remoteControlLegacyStreamIds.removeAll()
        remoteControlClientSegmentReassembler = RemoteControlClientSegmentReassembler()
        remoteControlLastCompletedClientChunkSeqIds.removeAll()
        for client in clients {
            await client.router.connectionClosed(client.connection)
        }
    }

    private func remoteControlEnrollmentFailed(generation: UInt64,
                                               conn: any ClientConnection) async {
        do {
            guard generation == remoteControlGeneration,
                  (try? currentRemoteControlState().status) != "disabled" else {
                return
            }
            let changed = try setRemoteControlStatus("errored", environmentId: nil)
            if changed, let response = try? remoteControlResponse() {
                await sendRemoteControlStatusChanged(response, conn: conn)
            }
        } catch {
            // The enable request has already been answered; keep async connection work
            // from crashing the router if the installation-id file becomes unavailable.
        }
    }

    @discardableResult
    private func setRemoteControlStatus(_ status: String,
                                        environmentId: String?) throws -> Bool {
        var state = try currentRemoteControlState()
        let previous = state
        state.status = status
        state.environmentId = environmentId
        remoteControlState = state
        return previous != state
    }

    private func remoteControlResponse() throws -> JSONValue {
        let state = try currentRemoteControlState()
        return .object([
            "status": .string(state.status),
            "serverName": .string(state.serverName),
            "installationId": .string(state.installationId),
            "environmentId": state.environmentId.map(JSONValue.string) ?? .null,
        ])
    }

    private func sendRemoteControlStatusChanged(_ response: JSONValue,
                                                conn: any ClientConnection) async {
        await conn.send(ServerNotification.raw(
            method: "remoteControl/status/changed",
            params: response).toMessage())
    }

    private func currentRemoteControlState() throws -> RemoteControlState {
        if let remoteControlState { return remoteControlState }
        let state = RemoteControlState(
            status: "disabled",
            serverName: Self.localServerName(),
            installationId: try Self.remoteControlInstallationId(codexHome: codexHome),
            environmentId: nil)
        remoteControlState = state
        return state
    }

    /// First name used for `{{ user_first_name }}` substitution in the realtime
    /// backend prompt. Port of `realtime_prompt.rs::current_user_first_name`:
    /// try the real name then the username, take the first whitespace-delimited
    /// token of whichever is non-empty, else fall back to "there". On macOS
    /// `NSFullUserName()` ≈ `whoami::realname()`, `NSUserName()` ≈ `whoami::username()`.
    private static func currentUserFirstName() -> String {
        for source in [NSFullUserName(), NSUserName()] {
            if let first = source.split(whereSeparator: { $0.isWhitespace }).first,
               !first.isEmpty {
                return String(first)
            }
        }
        return Templates.realtimeDefaultUserFirstName
    }

    private static func localServerName() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["HOSTNAME"],
            ProcessInfo.processInfo.environment["COMPUTERNAME"],
            NSUserName().isEmpty ? nil : NSUserName(),
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "codexkit"
    }

    private static func remoteControlInstallationId(codexHome: String) throws -> String {
        let file = URL(fileURLWithPath: codexHome)
            .appendingPathComponent("remote-control-installation-id")
        if let existing = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fresh = UUID().uuidString.lowercased()
        try fresh.write(to: file, atomically: true, encoding: .utf8)
        return fresh
    }

    private static let supportedRuntimeFeatureEnablement: [String] = [
        "apps",
        "memories",
        "mentions_v2",
        "plugins",
        "remote_control",
        "tool_search",
        "tool_suggest",
        "tool_call_mcp_elicitation",
    ]

    private static let knownCanonicalFeatureKeys: Set<String> = Set(
        supportedRuntimeFeatureEnablement + [
            "apply_patch_freeform",
            "auth_elicitation",
            "browser_use",
            "browser_use_external",
            "chronicle",
            "collab",
            "codex_hooks",
            "computer_use",
            "image_detail_original",
            "in_app_browser",
            "js_repl",
            "js_repl_tools_only",
            "network_proxy",
            "personality",
            "remote_compaction_v2",
            "responses_websocket_response_processed",
            "terminal_resize_reflow",
            "use_legacy_landlock",
            "use_linux_sandbox_bwrap",
            "web_search",
            "workspace_dependencies",
        ])

    private static let legacyRuntimeFeatureAliases: [String: String] = [
        "connectors": "apps",
        "memory_tool": "memories",
        "collab": "collab",
        "codex_hooks": "codex_hooks",
        "telepathy": "chronicle",
    ]

    private func handleExperimentalFeatureEnablementRequest(id: RequestId, method: String,
                                                            params: JSONValue?,
                                                            conn: any ClientConnection) async -> Bool {
        guard method == "experimentalFeature/enablement/set" else { return false }
        guard let enablement = params?["enablement"]?.objectValue else {
            await conn.send(WireError.invalidRequest(
                id: id, "experimentalFeature/enablement/set requires enablement"))
            return true
        }
        for (key, value) in enablement {
            guard value.boolValue != nil else {
                await conn.send(WireError.invalidRequest(
                    id: id, "invalid feature enablement `\(key)`: expected boolean"))
                return true
            }
            if Self.supportedRuntimeFeatureEnablement.contains(key) { continue }
            if Self.knownCanonicalFeatureKeys.contains(key) {
                await conn.send(WireError.invalidRequest(
                    id: id,
                    "unsupported feature enablement `\(key)`: currently supported features are \(Self.supportedRuntimeFeatureEnablement.joined(separator: ", "))"))
                return true
            }
            if let canonical = Self.legacyRuntimeFeatureAliases[key] {
                await conn.send(WireError.invalidRequest(
                    id: id,
                    "invalid feature enablement `\(key)`: use canonical feature key `\(canonical)`"))
                return true
            }
            await conn.send(WireError.invalidRequest(
                id: id, "invalid feature enablement `\(key)`"))
            return true
        }

        var updated: [String: JSONValue] = [:]
        for (key, value) in enablement {
            let enabled = value.boolValue ?? false
            runtimeFeatureEnablement[key] = enabled
            updated[key] = .bool(enabled)
        }
        await reply(conn, id, .object(["enablement": .object(updated)]))
        if updated["apps"] == .bool(true) {
            if let response = try? Self.appsListResponse(
                codexHome: codexHome,
                params: AppsListParams(forceRefetch: true),
                runtimeFeatureEnablement: runtimeFeatureEnablement),
               !response.data.isEmpty {
                await conn.send(.notification(JSONRPCNotification(
                    method: "app/list/updated",
                    params: .object(["data": .array(response.data)]))))
            }
        }
        return true
    }

    private func runtimeFeaturesJSON(base: JSONValue?, config: Config) -> JSONValue {
        var features = base?.objectValue ?? [:]
        for key in Self.supportedRuntimeFeatureEnablement {
            let enabled = runtimeFeatureEnablement[key] ?? config.isFeatureEnabled(key)
            features[key] = .bool(enabled)
        }
        return .object(features)
    }

    private func experimentalFeatureListResponse() -> ExperimentalFeatureListResponse {
        let config = ConfigLoader(codexHome: codexHome).load()
        let data = Self.supportedRuntimeFeatureEnablement.map { key in
            let enabled = runtimeFeatureEnablement[key] ?? config.isFeatureEnabled(key)
            return JSONValue.object([
                "name": .string(key),
                "stage": .string("beta"),
                "displayName": .string(Self.runtimeFeatureDisplayName(key)),
                "description": .string(Self.runtimeFeatureDescription(key)),
                "announcement": .null,
                "enabled": .bool(enabled),
                "defaultEnabled": .bool(false),
            ])
        }
        return ExperimentalFeatureListResponse(data: data, nextCursor: nil)
    }

    private static func runtimeFeatureDisplayName(_ key: String) -> String {
        key.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func runtimeFeatureDescription(_ key: String) -> String {
        "Runtime enablement for \(key)."
    }

    private static func collaborationModeListResponse() -> CollaborationModeListResponse {
        CollaborationModeListResponse(data: [
            .object([
                "name": .string("Plan"),
                "mode": .string("plan"),
                "model": .null,
                "reasoning_effort": .string("medium"),
            ]),
            .object([
                "name": .string("Default"),
                "mode": .string("default"),
                "model": .null,
                "reasoning_effort": .null,
            ]),
        ])
    }

    private static func conversationSummaryJSON(_ summary: ConversationSummaryState) -> JSONValue {
        .object([
            "conversationId": .string(summary.conversationId.raw),
            "path": .string(summary.path),
            "preview": .string(summary.preview),
            "timestamp": summary.timestamp.map(JSONValue.string) ?? .null,
            "updatedAt": summary.updatedAt.map(JSONValue.string) ?? .null,
            "modelProvider": .string(summary.modelProvider),
            "cwd": .string(summary.cwd),
            "cliVersion": .string(summary.cliVersion),
            "source": summary.source,
            "gitInfo": summary.gitInfo ?? .null,
        ])
    }

    private func getAccountResponse(refreshToken: Bool) async throws -> GetAccountResponse {
        let requiresOpenAIAuth = currentProviderRequiresOpenAIAuth()
        guard requiresOpenAIAuth else {
            return GetAccountResponse(account: nil, requiresOpenaiAuth: false)
        }
        guard let auth else {
            return GetAccountResponse(account: nil, requiresOpenaiAuth: true)
        }
        if refreshToken,
           let initialTokens = await auth.storedTokens(),
           initialTokens.refreshToken != nil,
           initialTokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame {
            _ = await auth.refreshAccessToken()
        }
        guard let tokens = await auth.storedTokens(),
              !(await auth.hasRefreshFailure(for: tokens)) else {
            return GetAccountResponse(account: nil, requiresOpenaiAuth: true)
        }
        return GetAccountResponse(
            account: try Self.accountJSON(for: tokens),
            requiresOpenaiAuth: true)
    }

    private func currentProviderRequiresOpenAIAuth() -> Bool {
        let config = ConfigLoader(codexHome: codexHome).load()
        let object = config.configObjectJSON()
        let providerId = object["model_provider"]?.stringValue
            ?? object["modelProvider"]?.stringValue
            ?? object["model_provider_id"]?.stringValue
        // Use the throwing entry point so an invalid provider config (e.g.
        // `wire_api = "chat"`, which upstream rejects) does not silently
        // degrade to the built-in default registry. If validation fails we
        // log to stderr and fall back to `requiresOpenAIAuth = true`, the
        // safer default: the client will be told it needs auth rather than
        // silently being granted "no auth required" because of bad config.
        do {
            let registry = try ModelProviderRegistry.load(
                from: object.mapValues(Self.configValueLite(_:)))
            return registry.resolve(providerId).requiresOpenAIAuth
        } catch {
            FileHandle.standardError.write(Data(
                ("codex-supervisor: invalid model_providers config "
                 + "(\(error)); defaulting requiresOpenAIAuth=true\n").utf8))
            return true
        }
    }

    private static func configValueLite(_ value: ConfigValue) -> ConfigValueLite {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .int(Int64(d))
        case .string(let s): return .string(s)
        case .array(let values): return .array(values.map(configValueLite(_:)))
        case .object(let object): return .object(object.mapValues(configValueLite(_:)))
        }
    }

    /// Signals that a ChatGPT-authenticated token is missing the `email` or
    /// `plan_type` JWT claims. Upstream maps this to an `invalid_request`
    /// error ("email and plan type are required for chatgpt authentication")
    /// rather than fabricating an empty email / "unknown" plan.
    /// (model-provider/src/provider.rs:216-223,
    ///  account_processor.rs:818-824)
    struct MissingChatgptAccountDetails: Error {}

    private static func accountJSON(for tokens: AuthTokens) throws -> JSONValue? {
        switch tokens.tokenType.lowercased() {
        case "apikey":
            return .object(["type": .string("apiKey")])
        case "bearer", "bearerexternal":
            // Upstream sources email/plan EXCLUSIVELY from the id_token JWT
            // claims (`AuthManager::get_account_email` / `account_plan_type`,
            // manager.rs:357-388), never the access_token. Decoding the
            // access_token as a fallback could surface a chatgpt account where
            // upstream would treat the email as absent and reject.
            let claims = tokenClaims(tokens.idToken)
            // Upstream (`model-provider/src/provider.rs:216-223`) requires an
            // email for ChatGPT auth, but the plan type defaults to "unknown"
            // when the claim is absent (`AuthManager::account_plan_type` ->
            // `AccountPlanType::Unknown`). Only a missing email is fatal.
            guard let email = claims?.email else {
                throw MissingChatgptAccountDetails()
            }
            return .object([
                "type": .string("chatgpt"),
                "email": .string(email),
                "planType": .string(claims?.planType ?? "unknown"),
            ])
        default:
            return tokens.accessToken.isEmpty ? nil : .object(["type": .string("apiKey")])
        }
    }

    private struct TokenClaims {
        var email: String?
        var planType: String?
    }

    private static func tokenClaims(_ token: String?) -> TokenClaims? {
        guard let object = decodeJWTPayload(token) else { return nil }
        // Email may live at the top level or nested under the OpenAI profile
        // claim (`https://api.openai.com/profile`), mirroring upstream
        // `parse_chatgpt_jwt_claims` (`IdClaims::email.or(profile.email)`).
        let email = object["email"] as? String
            ?? (object["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
        return TokenClaims(email: email, planType: chatgptPlanType(token))
    }

    /// Resolve `forced_chatgpt_workspace_id` from config as a normalized list,
    /// mirroring upstream `Option<Vec<String>>` (config_toml.rs:234 accepts
    /// either a single string or a TOML list). Returns nil when unset/empty so
    /// the caller skips the allow-list check (upstream `if let Some(..)`).
    static func forcedChatgptWorkspaceIds(codexHome: String) -> [String]? {
        let value = ConfigLoader(codexHome: codexHome)
            .load().value("forced_chatgpt_workspace_id")
        let ids: [String]
        switch value {
        case .string(let s):
            ids = [s]
        case .array(let arr):
            ids = arr.compactMap { $0.stringValue }
        default:
            return nil
        }
        return ids.isEmpty ? nil : ids
    }

    private static func authMethod(for tokens: AuthTokens) -> String? {
        switch tokens.tokenType.lowercased() {
        case "apikey":
            return "apikey"
        case "bearerexternal":
            return "chatgptAuthTokens"
        case "bearer":
            return "chatgpt"
        default:
            return tokens.accessToken.isEmpty ? nil : "chatgpt"
        }
    }

    private static func authStatusJSON(authMethod: String?,
                                       authToken: String?,
                                       requiresOpenaiAuth: Bool) -> JSONValue {
        .object([
            "authMethod": authMethod.map(JSONValue.string) ?? .null,
            "authToken": authToken.map(JSONValue.string) ?? .null,
            "requiresOpenaiAuth": .bool(requiresOpenaiAuth),
        ])
    }

    private func handleFuzzyFileSearchRequest(id: RequestId, method: String,
                                              params: JSONValue?,
                                              conn: any ClientConnection) async -> Bool {
        guard method == "fuzzyFileSearch"
                || method == "fuzzyFileSearch/sessionStart"
                || method == "fuzzyFileSearch/sessionUpdate"
                || method == "fuzzyFileSearch/sessionStop" else { return false }
        switch method {
        case "fuzzyFileSearch":
            guard let query = params?["query"]?.stringValue,
                  let rootValues = params?["roots"]?.arrayValue else {
                await conn.send(WireError.invalidRequest(id: id, "fuzzyFileSearch requires query and roots"))
                return true
            }
            guard let roots = parseStringArray(rootValues) else {
                await conn.send(WireError.invalidRequest(id: id, "fuzzyFileSearch roots must be strings"))
                return true
            }
            let results = Self.runFuzzyFileSearch(query: query, roots: roots)
            await reply(conn, id, .object(["files": .array(results)]))
        case "fuzzyFileSearch/sessionStart":
            guard let sessionId = params?["sessionId"]?.stringValue, !sessionId.isEmpty,
                  let rootValues = params?["roots"]?.arrayValue else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fuzzyFileSearch/sessionStart requires sessionId and roots"))
                return true
            }
            guard let roots = parseStringArray(rootValues) else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fuzzyFileSearch/sessionStart roots must be strings"))
                return true
            }
            let key = FuzzySearchSessionKey(
                connection: ObjectIdentifier(conn as AnyObject),
                sessionId: sessionId)
            fuzzySearchSessions[key]?.updateTask?.cancel()
            fuzzySearchSessions[key] = FuzzySearchSession(roots: roots, updateTask: nil)
            await reply(conn, id, EmptyResponse())
        case "fuzzyFileSearch/sessionUpdate":
            guard let sessionId = params?["sessionId"]?.stringValue, !sessionId.isEmpty,
                  let query = params?["query"]?.stringValue else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fuzzyFileSearch/sessionUpdate requires sessionId and query"))
                return true
            }
            let key = FuzzySearchSessionKey(
                connection: ObjectIdentifier(conn as AnyObject),
                sessionId: sessionId)
            guard var session = fuzzySearchSessions[key] else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fuzzy file search session not found: \(sessionId)"))
                return true
            }
            session.updateTask?.cancel()
            let roots = session.roots
            await reply(conn, id, EmptyResponse())
            let task = Task.detached(priority: .utility) {
                let files = Self.runFuzzyFileSearch(query: query, roots: roots)
                if Task.isCancelled { return }
                await conn.send(.notification(JSONRPCNotification(
                    method: "fuzzyFileSearch/sessionUpdated",
                    params: .object([
                        "sessionId": .string(sessionId),
                        "query": .string(query),
                        "files": .array(files),
                    ]))))
                if Task.isCancelled { return }
                await conn.send(.notification(JSONRPCNotification(
                    method: "fuzzyFileSearch/sessionCompleted",
                    params: .object([
                        "sessionId": .string(sessionId),
                    ]))))
            }
            session.updateTask = task
            fuzzySearchSessions[key] = session
        case "fuzzyFileSearch/sessionStop":
            guard let sessionId = params?["sessionId"]?.stringValue, !sessionId.isEmpty else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fuzzyFileSearch/sessionStop requires sessionId"))
                return true
            }
            let key = FuzzySearchSessionKey(
                connection: ObjectIdentifier(conn as AnyObject),
                sessionId: sessionId)
            fuzzySearchSessions.removeValue(forKey: key)?.updateTask?.cancel()
            await reply(conn, id, EmptyResponse())
        default:
            return false
        }
        return true
    }

    private func cancelFuzzySearchSessions(connection: ObjectIdentifier) async {
        let owned = fuzzySearchSessions.filter { $0.key.connection == connection }
        for key in owned.keys {
            fuzzySearchSessions.removeValue(forKey: key)?.updateTask?.cancel()
        }
        for session in owned.values {
            await session.updateTask?.value
        }
    }

    private func parseStringArray(_ values: [JSONValue]) -> [String]? {
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }

    private func handlePluginRequest(id: RequestId, method: String,
                                     params: JSONValue?,
                                     conn: any ClientConnection) async -> Bool {
        guard method == "plugin/list" || method == "plugin/installed" || method == "plugin/read"
                || method == "plugin/skill/read" || method == "plugin/install"
                || method == "plugin/uninstall" || method == "plugin/share/save"
                || method == "plugin/share/updateTargets" || method == "plugin/share/list"
                || method == "plugin/share/checkout" || method == "plugin/share/delete"
        else { return false }
        do {
            switch method {
            case "plugin/list":
                let cwds = params?["cwds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let response = try Self.pluginListResponse(codexHome: codexHome, cwds: cwds)
                await reply(conn, id, response)
            case "plugin/installed":
                let cwds = params?["cwds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let suggestions = Set(params?["installSuggestionPluginNames"]?.arrayValue?
                    .compactMap(\.stringValue) ?? [])
                let response = try Self.pluginInstalledResponse(
                    codexHome: codexHome, cwds: cwds, installSuggestionPluginNames: suggestions)
                await reply(conn, id, response)
            case "plugin/read":
                let response = try Self.pluginReadResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "plugin/skill/read":
                let response = try Self.pluginSkillReadResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "plugin/install":
                let response = try Self.pluginInstallResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "plugin/uninstall":
                let response = try Self.pluginUninstallResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "plugin/share/save":
                let response = try Self.pluginShareSaveResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "plugin/share/updateTargets":
                let response = try Self.pluginShareUpdateTargetsResponse(
                    codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "plugin/share/list":
                let response = try Self.pluginShareListResponse(codexHome: codexHome)
                await reply(conn, id, response)
            case "plugin/share/checkout":
                let response = try Self.pluginShareCheckoutResponse(
                    codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "plugin/share/delete":
                let response = try Self.pluginShareDeleteResponse(
                    codexHome: codexHome, params: params)
                await reply(conn, id, response)
            default:
                break
            }
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private func handleMarketplaceRequest(id: RequestId, method: String,
                                          params: JSONValue?,
                                          conn: any ClientConnection) async -> Bool {
        guard method == "marketplace/add" || method == "marketplace/remove"
                || method == "marketplace/upgrade" else { return false }
        do {
            switch method {
            case "marketplace/add":
                let response = try Self.marketplaceAddResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "marketplace/remove":
                let response = try Self.marketplaceRemoveResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            case "marketplace/upgrade":
                let response = try Self.marketplaceUpgradeResponse(codexHome: codexHome, params: params)
                await reply(conn, id, response)
            default:
                break
            }
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private func handleMcpServerRequest(id: RequestId, method: String,
                                        params: JSONValue?,
                                        conn: any ClientConnection) async -> Bool {
        switch method {
        case "config/mcpServer/reload":
            await mcpManager.stopAll()
            await ensureMcpServersStarted(conn: conn)
            await reply(conn, id, .object([:]))
            return true
        case "mcpServer/tool/call":
            Task { [self, conn, id, params] in
                do {
                    let result = try await callMcpTool(params: params, conn: conn)
                    await reply(conn, id, result)
                } catch {
                    await conn.send(WireError.invalidRequest(id: id, String(describing: error)))
                }
            }
            return true
        case "mcpServer/resource/read":
            do {
                let result = try await readMcpResource(params: params)
                await reply(conn, id, result)
            } catch {
                await conn.send(WireError.invalidRequest(id: id, String(describing: error)))
            }
            return true
        case "mcpServer/oauth/login":
            do {
                let response = try await mcpOAuthLoginResponse(params: params, conn: conn)
                await reply(conn, id, response)
            } catch {
                await conn.send(WireError.invalidRequest(id: id, String(describing: error)))
            }
            return true
        default:
            return false
        }
    }

    private func ensureMcpServersStarted(conn: (any ClientConnection)? = nil) async {
        let configs = McpManager.loadConfigs(codexHome: codexHome)
        // Stream per-server startup progress as `mcpServer/startupStatus/updated`
        // notifications when a connection is available (upstream
        // `EventMsg::McpStartupUpdate` → v2 `McpServerStatusUpdatedNotification`,
        // bespoke_event_handling.rs:196-218).
        var sink: McpManager.StartupStatusUpdate?
        if let c = conn {
            sink = { (server: String, status: McpServerStartupState, error: String?) in
                await c.send(ServerNotification.mcpServerStatusUpdated(
                    name: server, status: status, error: error).toMessage())
            }
        }
        await mcpManager.startAll(configs, onStatusUpdate: sink)
    }

    private func mcpStatusListResponse() async -> JSONValue {
        .object(["data": await mcpStatusListData(), "nextCursor": .null])
    }

    private func mcpStatusListData() async -> JSONValue {
        let statuses = await mcpManager.statusList()
        return .array(statuses.map(Self.mcpStatusJSON(_:)))
    }

    private static func mcpStatusJSON(_ status: McpServerStatus) -> JSONValue {
        var tools: [String: JSONValue] = [:]
        for tool in status.tools {
            let schema = jsonStringToValue(tool.inputSchemaJSON) ?? .object([:])
            tools[tool.name] = .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": schema,
            ])
        }
        return .object([
            "name": .string(status.name),
            "tools": .object(tools),
            "resources": .array([]),
            "resourceTemplates": .array([]),
            "authStatus": .string("notLoggedIn"),
            "status": .string(status.state),
            "error": status.error.map(JSONValue.string) ?? .null,
        ])
    }

    private func mcpOAuthLoginResponse(params: JSONValue?,
                                       conn: any ClientConnection) async throws -> JSONValue {
        guard let params else {
            throw SimpleError("mcpServer/oauth/login requires params")
        }
        guard let name = params["name"]?.stringValue, !name.isEmpty else {
            throw SimpleError("mcpServer/oauth/login requires name")
        }
        let configs = McpManager.loadConfigs(codexHome: codexHome)
        guard let cfg = configs.first(where: { $0.name == name }) else {
            throw SimpleError("No MCP server named '\(name)' found.")
        }
        guard let serverURL = cfg.url, !serverURL.isEmpty else {
            throw SimpleError("OAuth login is only supported for streamable HTTP servers.")
        }
        let timeout = params["timeoutSecs"]?.intValue.map { Swift.max(1, $0) } ?? 10
        guard let metadata = McpOAuth.discoverMetadata(serverURL: serverURL,
                                                       timeout: Double(timeout)),
              let authorizationEndpoint = metadata.authorizationEndpoint,
              !authorizationEndpoint.isEmpty,
              let tokenEndpoint = metadata.tokenEndpoint,
              !tokenEndpoint.isEmpty else {
            throw SimpleError("failed to discover OAuth metadata for MCP server '\(name)'")
        }

        let scopes = params["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        try await McpOAuthCallbackCoordinator.shared.register(
            state: state,
            name: name,
            tokenEndpoint: tokenEndpoint,
            verifier: pkce.verifier,
            timeout: Double(timeout),
            store: McpOAuthStore(codexHome: codexHome),
            notify: { [conn] success, error in
                var payload: [String: JSONValue] = [
                    "name": .string(name),
                    "success": .bool(success),
                ]
                if let error {
                    payload["error"] = .string(error)
                }
                await conn.send(ServerNotification.raw(
                    method: "mcpServer/oauthLogin/completed",
                    params: .object(payload)).toMessage())
            })
        let authorizationURL = Self.buildMcpAuthorizationURL(
            authorizationEndpoint: authorizationEndpoint,
            scopes: scopes,
            challenge: pkce.challenge,
            state: state)
        return .object(["authorizationUrl": .string(authorizationURL)])
    }

    private static func buildMcpAuthorizationURL(authorizationEndpoint: String,
                                                 scopes: [String],
                                                 challenge: String,
                                                 state: String) -> String {
        var components = URLComponents(string: authorizationEndpoint)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: "Codex"))
        items.append(URLQueryItem(name: "redirect_uri",
                                  value: McpOAuth.redirectURI))
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        items.append(URLQueryItem(name: "code_challenge", value: challenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        items.append(URLQueryItem(name: "state", value: state))
        components?.queryItems = items
        return components?.url?.absoluteString ?? authorizationEndpoint
    }

    private func callMcpTool(params: JSONValue?, conn: any ClientConnection) async throws
        -> JSONValue {
        guard let params else { throw SimpleError("mcpServer/tool/call requires params") }
        guard let threadIdRaw = params["threadId"]?.stringValue,
              ThreadId(threadIdRaw).isWellFormed else {
            throw SimpleError("mcpServer/tool/call requires valid threadId")
        }
        guard let server = params["server"]?.stringValue, !server.isEmpty else {
            throw SimpleError("mcpServer/tool/call requires server")
        }
        guard let tool = params["tool"]?.stringValue, !tool.isEmpty else {
            throw SimpleError("mcpServer/tool/call requires tool")
        }
        let argsData = try JSONEncoder().encode(params["arguments"] ?? .object([:]))
        let argsJSON = String(decoding: argsData, as: UTF8.self)
        let threadId = ThreadId(threadIdRaw)
        if let workerResult = await requestWorkerMcpTool(threadId: threadId,
                                                         server: server,
                                                         tool: tool,
                                                         argumentsJSON: argsJSON) {
            return try workerResult.get()
        }
        await ensureMcpServersStarted()
        // Upstream parity (codex-mcp/src/elicitation.rs::make_sender): apply the
        // elicitation policy before surfacing a prompt. Resolve the effective
        // approval policy + sandbox from the loaded config (this direct
        // `mcpServer/tool/call` path has no per-turn SessionConfig threaded in).
        let elicitConfig = ConfigLoader(codexHome: codexHome).load()
        let elicitPolicy = Self.approvalPolicyFallback(from: elicitConfig)
        let elicitSandbox = Self.sandboxMode(from: nil, fallbackConfig: elicitConfig)
        let elicitAutoApproved =
            elicitPolicy == .never && elicitSandbox == .dangerFullAccess
        let handler: McpElicitationHandler = { [weak self, conn] requestId, serverName, params in
            guard let self else { return nil }
            switch McpElicitationPolicy.decide(approvalPolicy: elicitPolicy,
                                               autoDeny: false,
                                               autoApproved: elicitAutoApproved,
                                               params: params) {
            case .decline:
                return .object(["action": .string("decline")])
            case .accept:
                return .object(["action": .string("accept"),
                                "content": .object([:])])
            case .prompt:
                break
            }
            let appParams = Self.mcpElicitationParams(threadId: threadId,
                                                      serverName: serverName,
                                                      params: params)
            return await self.requestDirectServerResponse(
                ServerRequest.mcpElicitation(requestId, appParams),
                conn: conn)
        }
        let result = try await mcpManager.callTool(server: server, tool: tool,
                                                   argumentsJSON: argsJSON,
                                                   elicitationHandler: handler)
        // Finding 2 (v7): surface the FULL MCP CallToolResult — the complete
        // content block array, structuredContent, and result `_meta` — instead
        // of collapsing everything to a single concatenated text block. Mirrors
        // upstream `connection_manager.rs::call_tool` which preserves all of it.
        let content: JSONValue
        if result.content.isEmpty {
            content = .array([
                .object(["type": .string("text"), "text": .string(result.text)])
            ])
        } else {
            content = .array(result.content.map(Self.jsonLiteToValue(_:)))
        }
        return .object([
            "content": content,
            "structuredContent": result.structuredContent.map(Self.jsonLiteToValue(_:)) ?? .null,
            "isError": .bool(result.isError),
            "_meta": result.meta.map(Self.jsonLiteToValue(_:)) ?? .null,
        ])
    }

    private func readMcpResource(params: JSONValue?) async throws -> JSONValue {
        guard let params else { throw SimpleError("mcpServer/resource/read requires params") }
        guard let server = params["server"]?.stringValue, !server.isEmpty else {
            throw SimpleError("mcpServer/resource/read requires server")
        }
        guard let uri = params["uri"]?.stringValue, !uri.isEmpty else {
            throw SimpleError("mcpServer/resource/read requires uri")
        }
        if let threadIdRaw = params["threadId"]?.stringValue,
           !ThreadId(threadIdRaw).isWellFormed {
            throw SimpleError("mcpServer/resource/read requires valid threadId")
        }
        if let threadIdRaw = params["threadId"]?.stringValue {
            let threadId = ThreadId(threadIdRaw)
            if let workerResult = await requestWorkerMcpResource(threadId: threadId,
                                                                 server: server,
                                                                 uri: uri) {
                return try workerResult.get()
            }
        }
        await ensureMcpServersStarted()
        let result = try await mcpManager.readResource(server: server, uri: uri)
        return .object(result.mapValues(Self.jsonLiteToValue(_:)))
    }

    private func requestWorkerMcpTool(threadId: ThreadId,
                                      server: String,
                                      tool: String,
                                      argumentsJSON: String) async
        -> Result<JSONValue, any Error>? {
        let requestId = "mcp-\(threadId.raw)-\(UUID().uuidString)"
        let request = WorkerMcpRequest(requestId: requestId,
                                       kind: .callTool,
                                       threadId: threadId,
                                       server: server,
                                       tool: tool,
                                       argumentsJSON: argumentsJSON)
        guard let response = await supervisor.requestMcp(request) else { return nil }
        if let error = response.error { return .failure(SimpleError(error)) }
        return .success(response.result ?? .object([:]))
    }

    private func requestWorkerMcpResource(threadId: ThreadId,
                                          server: String,
                                          uri: String) async
        -> Result<JSONValue, any Error>? {
        let requestId = "mcp-\(threadId.raw)-\(UUID().uuidString)"
        let request = WorkerMcpRequest(requestId: requestId,
                                       kind: .readResource,
                                       threadId: threadId,
                                       server: server,
                                       uri: uri)
        guard let response = await supervisor.requestMcp(request) else { return nil }
        if let error = response.error { return .failure(SimpleError(error)) }
        return .success(response.result ?? .object([:]))
    }

    private static func jsonLiteToValue(_ value: JSONLite) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            if n.isFinite, n.rounded() == n,
               n >= -9_223_372_036_854_775_808.0,
               n <  9_223_372_036_854_775_808.0 {
                return .int(Int64(n))
            }
            return .double(n)
        case .string(let s):
            return .string(s)
        case .array(let a):
            return .array(a.map(jsonLiteToValue(_:)))
        case .object(let o):
            return .object(o.mapValues(jsonLiteToValue(_:)))
        }
    }

    private static func mcpElicitationParams(threadId: ThreadId, serverName: String,
                                             params: JSONValue) -> McpElicitationParams {
        let mode = params["requestedSchema"] == nil ? "url" : "form"
        return McpElicitationParams(
            threadId: threadId,
            turnId: nil,
            serverName: serverName,
            mode: mode,
            meta: McpElicitationPolicy.scrubMeta(params["_meta"]),
            message: params["message"]?.stringValue ?? "",
            requestedSchema: params["requestedSchema"],
            url: params["url"]?.stringValue,
            elicitationId: params["elicitationId"]?.stringValue)
    }

    private func requestDirectServerResponse(_ request: ServerRequest,
                                             conn: any ClientConnection) async -> JSONValue? {
        let requestId = request.id.description
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            await self?.resolveDirectServerResponse(requestId, result: nil)
        }
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<JSONValue?, Never>) in
            pendingDirectServerResponses[requestId] = continuation
            Task { await conn.send(request.toMessage()) }
        }
        timeoutTask.cancel()
        return result
    }

    @discardableResult
    private func resolveDirectServerResponse(_ requestId: String,
                                             result: JSONValue?) -> Bool {
        guard let continuation = pendingDirectServerResponses.removeValue(
            forKey: requestId) else { return false }
        continuation.resume(returning: result)
        return true
    }

    private static func configValueToJSON(_ value: ConfigValue) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .string(let s):
            return .string(s)
        case .array(let a):
            return .array(a.map(configValueToJSON(_:)))
        case .object(let o):
            return .object(o.mapValues(configValueToJSON(_:)))
        }
    }

    private static func jsonAnyToValue(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let n as NSNumber:
            if String(cString: n.objCType) == "c" {
                return .bool(n.boolValue)
            }
            let d = n.doubleValue
            if d.isFinite, d.rounded() == d,
               d >= -9_223_372_036_854_775_808.0,
               d <  9_223_372_036_854_775_808.0 {
                return .int(n.int64Value)
            }
            return .double(d)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(jsonAnyToValue(_:)))
        case let o as [String: Any]:
            return .object(o.mapValues(jsonAnyToValue(_:)))
        default:
            return .null
        }
    }

    private static func jsonStringToValue(_ raw: String) -> JSONValue? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func handleFeedbackUploadRequest(id: RequestId, method: String,
                                             params: JSONValue?,
                                             conn: any ClientConnection) async -> Bool {
        guard method == "feedback/upload" else { return false }
        do {
            guard Self.feedbackUploadEnabled(codexHome: codexHome, config: config) else {
                throw SimpleError("sending feedback is disabled by configuration")
            }
            let result = try await Self.spoolFeedbackUpload(codexHome: codexHome,
                                                            store: store,
                                                            params: params)
            await reply(conn, id, .object(["threadId": .string(result.threadId)]))
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private struct FeedbackUploadSpoolResult {
        var threadId: String
        var bundlePath: String
    }

    private static func feedbackUploadEnabled(codexHome: String, config: Config?) -> Bool {
        if let config { return config.feedbackEnabled }
        guard let root = try? readUserConfigTOML(path: codexHome + "/config.toml"),
              case .object(let feedback)? = root["feedback"],
              let enabled = feedback["enabled"]?.boolValue else {
            return true
        }
        return enabled
    }

    private static func spoolFeedbackUpload(codexHome: String,
                                            store: ThreadStore,
                                            params: JSONValue?) async throws
        -> FeedbackUploadSpoolResult {
        guard let params else { throw SimpleError("feedback/upload requires params") }
        guard let classification = params["classification"]?.stringValue,
              !classification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimpleError("feedback/upload requires classification")
        }
        guard let includeLogs = params["includeLogs"]?.boolValue else {
            throw SimpleError("feedback/upload requires includeLogs")
        }
        let reason = try optionalString(params["reason"], field: "reason")
        let requestedThreadId = try optionalString(params["threadId"], field: "threadId")
        let threadId = try feedbackThreadId(requestedThreadId)
        let extraLogFiles = try optionalStringArray(params["extraLogFiles"],
                                                    field: "extraLogFiles")
        let tags = try optionalStringMap(params["tags"], field: "tags")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let bundleName = "\(timestamp.replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString)"
        let bundleURL = URL(fileURLWithPath: codexHome)
            .appendingPathComponent("feedback", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
        let attachmentsURL = bundleURL.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsURL,
                                                withIntermediateDirectories: true)

        var attachments: [JSONValue] = []
        if includeLogs {
            let logURL = attachmentsURL.appendingPathComponent("codex-logs.log")
            var logData = FeedbackLogStore.shared.renderFeedbackLogs(threadIds: [threadId])
            if logData.isEmpty {
                logData = Data("swift feedback upload\nthreadId=\(threadId)\ncreatedAt=\(timestamp)\n".utf8)
            }
            try logData.write(to: logURL, options: [.atomic])
            attachments.append(.object([
                "filename": .string("codex-logs.log"),
                "source": .string("feedbackLogStore"),
                "path": .string(logURL.path),
                "bytes": .int(Int64((try? Data(contentsOf: logURL).count) ?? 0)),
            ]))

            let rolloutPath = codexHome + "/sessions/\(threadId).rollout.jsonl"
            if FileManager.default.fileExists(atPath: rolloutPath) {
                let rolloutURL = attachmentsURL.appendingPathComponent("rollout-\(threadId).jsonl")
                try copyFileIfPresent(from: rolloutPath, to: rolloutURL.path)
                attachments.append(.object([
                    "filename": .string(rolloutURL.lastPathComponent),
                    "source": .string("rollout"),
                    "path": .string(rolloutURL.path),
                    "bytes": .int(Int64((try? Data(contentsOf: rolloutURL).count) ?? 0)),
                ]))
            } else if includeLogs {
                _ = try? await store.reconstruct(ThreadId(threadId))
            }
        }
        for extra in extraLogFiles {
            let sourceURL = URL(fileURLWithPath: extra)
            guard let safeName = safeAttachmentName(sourceURL.lastPathComponent) else {
                continue
            }
            let targetURL = attachmentsURL.appendingPathComponent(safeName)
            try copyFileIfPresent(from: sourceURL.path, to: targetURL.path)
            attachments.append(.object([
                "filename": .string(safeName),
                "source": .string("extraLogFile"),
                "originalPath": .string(sourceURL.path),
                "path": .string(targetURL.path),
                "bytes": .int(Int64((try? Data(contentsOf: targetURL).count) ?? 0)),
            ]))
        }

        let manifest: JSONValue = .object([
            "gate": .string("feedback/upload"),
            "result": .string("spooled"),
            "createdAt": .string(timestamp),
            "threadId": .string(threadId),
            "classification": .string(classification),
            "reason": reason.map(JSONValue.string) ?? .null,
            "includeLogs": .bool(includeLogs),
            "tags": .object(tags.mapValues(JSONValue.string)),
            "installContext": installContextJSON(InstallContext.current(codexHome: codexHome)),
            "attachments": .array(attachments),
        ])
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        try writeJSONValue(manifest, to: manifestURL.path)
        return FeedbackUploadSpoolResult(threadId: threadId, bundlePath: bundleURL.path)
    }

    private static func feedbackThreadId(_ requested: String?) throws -> String {
        if let requested {
            let tid = ThreadId(requested)
            guard tid.isWellFormed else {
                throw SimpleError("invalid thread id: unsafe thread id rejected")
            }
            return tid.raw
        }
        return "no-active-thread-\(ThreadId.generate().raw)"
    }

    private static func installContextJSON(_ context: InstallContext) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string(context.kind),
            "rgCommand": .string(context.rgCommand()),
        ]
        if case .standalone(let releaseDir, let resourcesDir, let platform) = context {
            object["releaseDir"] = .string(releaseDir)
            object["resourcesDir"] = resourcesDir.map(JSONValue.string) ?? .null
            object["platform"] = .string(platform.rawValue)
        }
        return .object(object)
    }

    private static func optionalString(_ value: JSONValue?, field: String) throws -> String? {
        guard let value, !value.isNull else { return nil }
        guard let s = value.stringValue else { throw SimpleError("feedback/upload \(field) must be a string") }
        return s
    }

    private static func optionalStringArray(_ value: JSONValue?, field: String) throws -> [String] {
        guard let value, !value.isNull else { return [] }
        guard let values = value.arrayValue else {
            throw SimpleError("feedback/upload \(field) must be an array")
        }
        var strings: [String] = []
        for item in values {
            guard let s = item.stringValue else {
                throw SimpleError("feedback/upload \(field) entries must be strings")
            }
            strings.append(s)
        }
        return strings
    }

    private static func optionalStringMap(_ value: JSONValue?, field: String) throws -> [String: String] {
        guard let value, !value.isNull else { return [:] }
        guard let object = value.objectValue else {
            throw SimpleError("feedback/upload \(field) must be an object")
        }
        var map: [String: String] = [:]
        for (key, raw) in object {
            guard let s = raw.stringValue else {
                throw SimpleError("feedback/upload \(field) values must be strings")
            }
            map[key] = s
        }
        return map
    }

    private static func safeAttachmentName(_ name: String) -> String? {
        let fallback = name.isEmpty ? "extra-log.log" : name
        guard fallback != "." && fallback != ".." && !fallback.contains("/") && !fallback.contains("\0") else {
            return nil
        }
        return fallback
    }

    private static func copyFileIfPresent(from source: String, to target: String) throws {
        guard FileManager.default.fileExists(atPath: source) else { return }
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.copyItem(atPath: source, toPath: target)
    }

    private static func writeJSONValue(_ value: JSONValue, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private func handleHooksRequest(id: RequestId, method: String,
                                    params: JSONValue?,
                                    conn: any ClientConnection) async -> Bool {
        guard method == "hooks/list" else { return false }
        do {
            let cwds = try Self.hooksListCwds(params: params)
            let response = try Self.hooksListResponse(codexHome: codexHome, cwds: cwds)
            await reply(conn, id, response)
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private static func hooksListCwds(params: JSONValue?) throws -> [String] {
        guard let raw = params?["cwds"], !raw.isNull else {
            return [FileManager.default.currentDirectoryPath]
        }
        guard let values = raw.arrayValue else {
            throw SimpleError("hooks/list cwds must be an array")
        }
        let cwds = values.compactMap(\.stringValue)
            .map(standardizedPath(_:))
            .filter { !$0.isEmpty }
        return cwds.isEmpty ? [FileManager.default.currentDirectoryPath] : cwds
    }

    private static func hooksListResponse(codexHome: String,
                                          cwds: [String]) throws -> JSONValue {
        let config = try readUserConfigTOML(path: codexHome + "/config.toml")
        let state = hookState(config)
        let data = cwds.map { cwd -> JSONValue in
            let standardizedCwd = standardizedPath(cwd)
            let sources: [(String, String, String)] = [
                ("user", codexHome + "/hooks.json", codexHome),
                ("project", standardizedCwd + "/.codex/hooks.json", standardizedCwd),
            ]
            var hooks: [JSONValue] = []
            var errors: [JSONValue] = []
            var displayOrder = 0
            for (source, path, base) in sources {
                do {
                    let defs = try hookDefinitions(path: path)
                    for (index, def) in defs.enumerated() {
                        let event = def["event"]?.stringValue
                            ?? def["eventName"]?.stringValue
                            ?? def["event_name"]?.stringValue
                            ?? ""
                        guard let eventName = normalizedHookEventName(event),
                              let command = def["command"]?.stringValue,
                              !command.isEmpty else { continue }
                        let key = "\(path):\(eventName):\(index):0"
                        let enabled = state[key]?["enabled"]?.boolValue ?? true
                        let currentHash = stableHookHash(def)
                        let trustedHash = state[key]?["trusted_hash"]?.stringValue
                        let trustStatus: String
                        if let trustedHash {
                            trustStatus = trustedHash == currentHash ? "trusted" : "modified"
                        } else {
                            trustStatus = "untrusted"
                        }
                        let timeout = hookTimeout(def["timeout"] ?? def["timeoutSec"] ?? def["timeout_sec"])
                        hooks.append(.object([
                            "key": .string(key),
                            "eventName": .string(eventName),
                            "handlerType": .string(def["type"]?.stringValue ?? "command"),
                            "isManaged": .bool(false),
                            "matcher": def["matcher"] ?? .null,
                            "command": .string(resolveHookCommand(command, base: base)),
                            "timeoutSec": .int(Int64(timeout)),
                            "statusMessage": def["statusMessage"] ?? def["status_message"] ?? .null,
                            "sourcePath": .string(path),
                            "source": .string(source),
                            "pluginId": .null,
                            "displayOrder": .int(Int64(displayOrder)),
                            "enabled": .bool(enabled),
                            "currentHash": .string(currentHash),
                            "trustStatus": .string(trustStatus),
                        ]))
                        displayOrder += 1
                    }
                } catch {
                    errors.append(.object([
                        "sourcePath": .string(path),
                        "message": .string(error.localizedDescription),
                    ]))
                }
            }
            return .object([
                "cwd": .string(standardizedCwd),
                "hooks": .array(hooks),
                "warnings": .array([]),
                "errors": .array(errors),
            ])
        }
        return .object(["data": .array(data)])
    }

    private static func hookDefinitions(path: String) throws -> [[String: JSONValue]] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let rawHooks = value["hooks"]?.arrayValue ?? value.arrayValue ?? []
        return rawHooks.compactMap(\.objectValue)
    }

    private static func hookState(_ config: [String: ConfigValue])
    -> [String: [String: ConfigValue]] {
        guard case .object(let hooks)? = config["hooks"],
              case .object(let state)? = hooks["state"] else { return [:] }
        var out: [String: [String: ConfigValue]] = [:]
        for (key, value) in state {
            guard case .object(let entry) = value else { continue }
            out[key] = entry
        }
        return out
    }

    private static func normalizedHookEventName(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
        let lower = normalized.lowercased()
        let known: [String: String] = [
            "pre_tool_use": "pre_tool_use",
            "permission_request": "permission_request",
            "post_tool_use": "post_tool_use",
            "pre_compact": "pre_compact",
            "post_compact": "post_compact",
            "session_start": "session_start",
            "user_prompt_submit": "user_prompt_submit",
            "stop": "stop",
        ]
        if let event = known[lower] { return event }
        let camel = raw.reduce(into: "") { partial, char in
            if char.isUppercase { partial.append("_") }
            partial.append(char.lowercased())
        }.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return known[camel]
    }

    private static func hookTimeout(_ value: JSONValue?) -> Int {
        if let int = value?.intValue { return max(0, Int(int)) }
        return 60
    }

    private static func resolveHookCommand(_ command: String, base: String) -> String {
        let hookDir = standardizedPath(base + "/.codex/hooks") + "/"
        return command.replacingOccurrences(of: ".codex/hooks/",
                                            with: hookDir)
    }

    private static func stableHookHash(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(object))) ?? Data()
        return "fnv64:" + stableDataHash(data)
    }

    private static func stableDataHash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func pluginListResponse(codexHome: String, cwds: [String]) throws -> JSONValue {
        try pluginMarketplaceListResponse(
            codexHome: codexHome, cwds: cwds, includeEmptyMarketplaces: true) { _ in true }
    }

    private static func pluginInstalledResponse(codexHome: String,
                                                cwds: [String],
                                                installSuggestionPluginNames: Set<String>) throws -> JSONValue {
        try pluginMarketplaceListResponse(
            codexHome: codexHome, cwds: cwds, includeEmptyMarketplaces: false) { plugin in
            guard let id = plugin["id"]?.stringValue,
                  let name = plugin["name"]?.stringValue else {
                return false
            }
            return plugin["installed"]?.boolValue == true
                || (installSuggestionPluginNames.contains(name)
                    && plugin["installed"]?.boolValue == false
                    && plugin["enabled"]?.boolValue == false
                    && !id.isEmpty)
        }
    }

    private static func pluginMarketplaceListResponse(
        codexHome: String,
        cwds: [String],
        includeEmptyMarketplaces: Bool,
        includePlugin: (JSONValue) -> Bool) throws -> JSONValue {
        let config = try readUserConfigTOML(path: codexHome + "/config.toml")
        let sharesByPath = try pluginShareLedger(codexHome: codexHome).sharesByLocalPath
        var roots: [String] = []
        roots.append(contentsOf: configuredMarketplaceRoots(codexHome: codexHome, config: config))
        for cwd in cwds {
            let repo = findRepoRoot(startingAt: cwd) ?? standardizedPath(cwd)
            if marketplaceManifestPath(repo) != nil { roots.append(repo) }
        }
        roots = Array(Set(roots)).sorted()
        let marketplaces = try roots.compactMap { root -> JSONValue? in
            guard let path = marketplaceManifestPath(root),
                  let manifest = try readJSONObject(path: path),
                  let name = manifest["name"] as? String,
                  let rawPlugins = manifest["plugins"] as? [Any] else {
                return nil
            }
            let entries = try marketplacePluginEntries(marketplaceRoot: root)
            let plugins = rawPlugins.compactMap { raw -> JSONValue? in
                guard let object = raw as? [String: Any],
                      let pluginName = object["name"] as? String,
                      let entry = entries[pluginName] else {
                    return nil
                }
                let pluginKey = "\(pluginName)@\(name)"
                let installed = isPluginInstalled(codexHome: codexHome,
                                                  marketplaceName: name,
                                                  pluginName: pluginName)
                let enabled = pluginAlreadyEnabled(pluginKey: pluginKey, config: config)
                return pluginSummaryJSON(pluginKey: pluginKey, entry: entry,
                                         installed: installed, enabled: enabled,
                                         share: entry.sourcePath.flatMap { sharesByPath[$0] })
            }.filter {
                includePlugin($0)
            }
            guard includeEmptyMarketplaces || !plugins.isEmpty else { return nil }
            return .object([
                "name": .string(name),
                "path": .string(path),
                "interface": .null,
                "plugins": .array(plugins),
            ])
        }
        return .object([
            "marketplaces": .array(marketplaces),
            "marketplaceLoadErrors": .array([]),
            "featuredPluginIds": .array([]),
        ])
    }

    private static func pluginReadResponse(codexHome: String,
                                           params: JSONValue?) throws -> JSONValue {
        guard let params else { throw SimpleError("plugin/read requires params") }
        guard let pluginName = params["pluginName"]?.stringValue,
              isSafePluginSegment(pluginName) else {
            throw SimpleError("plugin/read requires pluginName")
        }
        let marketplacePath = params["marketplacePath"]?.stringValue
        let remoteMarketplaceName = params["remoteMarketplaceName"]?.stringValue
        guard (marketplacePath == nil) != (remoteMarketplaceName == nil) else {
            throw SimpleError("plugin/read requires exactly one of marketplacePath or remoteMarketplaceName")
        }
        let config = try readUserConfigTOML(path: codexHome + "/config.toml")
        let resolved = try resolveMarketplaceReadPath(
            codexHome: codexHome,
            config: config,
            marketplacePath: marketplacePath,
            remoteMarketplaceName: remoteMarketplaceName)
        guard let manifest = try readJSONObject(path: resolved.manifestPath),
              let marketplaceName = manifest["name"] as? String,
              let rawPlugins = manifest["plugins"] as? [Any] else {
            throw SimpleError("plugin/read marketplacePath must contain a supported marketplace.json")
        }
        let rawPlugin = rawPlugins.compactMap { $0 as? [String: Any] }
            .first { $0["name"] as? String == pluginName }
        guard let rawPlugin else {
            throw SimpleError("plugin/read could not find plugin \(pluginName)")
        }
        let entries = try marketplacePluginEntries(marketplaceRoot: resolved.root)
        guard let entry = entries[pluginName], let sourcePath = entry.sourcePath else {
            throw SimpleError("plugin/read could not resolve local plugin \(pluginName)")
        }
        guard let pluginManifestPath = pluginManifestPath(sourcePath),
              let pluginManifest = try readJSONObject(path: pluginManifestPath) else {
            throw SimpleError("plugin/read plugin \(pluginName) is missing plugin.json")
        }
        let pluginKey = "\(pluginName)@\(marketplaceName)"
        let installed = isPluginInstalled(codexHome: codexHome,
                                          marketplaceName: marketplaceName,
                                          pluginName: pluginName)
        let enabled = pluginAlreadyEnabled(pluginKey: pluginKey, config: config)
        let sharesByPath = try pluginShareLedger(codexHome: codexHome).sharesByLocalPath
        let summary = pluginSummaryJSON(
            pluginKey: pluginKey,
            entry: entry,
            installed: installed,
            enabled: enabled,
            share: sharesByPath[sourcePath],
            rawPlugin: rawPlugin,
            pluginManifest: pluginManifest)
        let description = (pluginManifest["description"] as? String)
        return .object([
            "plugin": .object([
                "marketplaceName": .string(marketplaceName),
                "marketplacePath": .string(resolved.manifestPath),
                "summary": summary,
                "description": description.map(JSONValue.string) ?? .null,
                "skills": .array(pluginSkillSummaries(
                    pluginRoot: sourcePath, pluginName: pluginName, config: config)),
                "hooks": .array(pluginHookSummaries(
                    pluginRoot: sourcePath, pluginKey: pluginKey)),
                "apps": .array(pluginAppSummaries(pluginRoot: sourcePath)),
                "mcpServers": .array(pluginMcpServerNames(pluginRoot: sourcePath).map(JSONValue.string)),
            ]),
        ])
    }

    private static func pluginSkillReadResponse(codexHome: String,
                                                params: JSONValue?) throws -> JSONValue {
        guard let params else { throw SimpleError("plugin/skill/read requires params") }
        guard let remotePluginId = params["remotePluginId"]?.stringValue,
              isValidRemotePluginId(remotePluginId),
              let skillName = params["skillName"]?.stringValue,
              isSafePluginSegment((skillName as NSString).lastPathComponent) else {
            throw SimpleError("plugin/skill/read requires remotePluginId and skillName")
        }
        let ledger = try pluginShareLedger(codexHome: codexHome)
        guard let entry = ledger.shares[remotePluginId] else {
            return .object(["contents": .null])
        }
        let skillTail = skillName.split(separator: ":").last.map(String.init) ?? skillName
        let safeSkill = (skillTail as NSString).lastPathComponent
        let path = entry.localPluginPath + "/skills/\(safeSkill)/SKILL.md"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .object(["contents": .null])
        }
        return .object(["contents": .string(contents)])
    }

    private static func marketplaceAddResponse(codexHome: String,
                                               params: JSONValue?) throws -> JSONValue {
        guard let source = params?["source"]?.stringValue,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimpleError("marketplace/add requires source")
        }
        let rootPath = standardizedPath(source)
        guard let manifestPath = marketplaceManifestPath(rootPath),
              let manifest = try readJSONObject(path: manifestPath),
              let manifestName = manifest["name"] as? String,
              isSafePluginSegment(manifestName) else {
            throw SimpleError("marketplace/add source must contain a supported marketplace.json")
        }
        let name = params?["refName"]?.stringValue
            .flatMap { isSafePluginSegment($0) ? $0 : nil } ?? manifestName
        let configPath = codexHome + "/config.toml"
        var root = try readUserConfigTOML(path: configPath)
        let alreadyAdded = configuredMarketplaceRoots(codexHome: codexHome, config: root)
            .contains(rootPath)
        try ensureMarketplaceConfig(name: name, marketplaceRoot: rootPath, root: &root)
        try writeUserConfigTOML(root, codexHome: codexHome)
        return .object([
            "marketplaceName": .string(name),
            "installedRoot": .string(rootPath),
            "alreadyAdded": .bool(alreadyAdded),
        ])
    }

    private static func marketplaceRemoveResponse(codexHome: String,
                                                  params: JSONValue?) throws -> JSONValue {
        guard let name = params?["marketplaceName"]?.stringValue,
              isSafePluginSegment(name) else {
            throw SimpleError("marketplace/remove requires marketplaceName")
        }
        let configPath = codexHome + "/config.toml"
        var root = try readUserConfigTOML(path: configPath)
        var installedRoot = ""
        if case .object(var marketplaces)? = root["marketplaces"] {
            if case .object(let table)? = marketplaces[name],
               case .string(let source)? = table["source"] {
                installedRoot = standardizedPath(source)
            }
            marketplaces.removeValue(forKey: name)
            root["marketplaces"] = marketplaces.isEmpty ? nil : .object(marketplaces)
        }
        try writeUserConfigTOML(root, codexHome: codexHome)
        return .object([
            "marketplaceName": .string(name),
            "installedRoot": .string(installedRoot),
        ])
    }

    private static func marketplaceUpgradeResponse(codexHome: String,
                                                   params: JSONValue?) throws -> JSONValue {
        let config = try readUserConfigTOML(path: codexHome + "/config.toml")
        let requested = params?["marketplaceName"]?.stringValue
        let roots = configuredMarketplaceRoots(codexHome: codexHome, config: config)
        var upgraded: [JSONValue] = []
        for root in roots {
            guard let manifestPath = marketplaceManifestPath(root),
                  let manifest = try readJSONObject(path: manifestPath),
                  let name = manifest["name"] as? String,
                  requested == nil || requested == name else { continue }
            let entries = try marketplacePluginEntries(marketplaceRoot: root)
            for entry in entries.values {
                guard let sourcePath = entry.sourcePath,
                      isPluginInstalled(codexHome: codexHome,
                                        marketplaceName: name,
                                        pluginName: entry.name) else { continue }
                try installLocalPlugin(codexHome: codexHome, marketplaceName: name,
                                       pluginName: entry.name, sourcePath: sourcePath)
                upgraded.append(.object([
                    "pluginId": .string("\(entry.name)@\(name)"),
                    "version": entry.version.map(JSONValue.string) ?? .null,
                ]))
            }
        }
        return .object(["upgraded": .array(upgraded)])
    }

    private static func pluginInstallResponse(codexHome: String,
                                             params: JSONValue?) throws -> JSONValue {
        guard let pluginName = params?["pluginName"]?.stringValue,
              isSafePluginSegment(pluginName) else {
            throw SimpleError("plugin/install requires pluginName")
        }
        let (marketplaceName, marketplaceRoot) = try resolveMarketplaceForPluginInstall(
            codexHome: codexHome, params: params, pluginName: pluginName)
        let entries = try marketplacePluginEntries(marketplaceRoot: marketplaceRoot)
        guard let entry = entries[pluginName], let sourcePath = entry.sourcePath else {
            throw SimpleError("plugin/install could not find local plugin \(pluginName)")
        }
        var root = try readUserConfigTOML(path: codexHome + "/config.toml")
        try ensureMarketplaceConfig(name: marketplaceName, marketplaceRoot: marketplaceRoot,
                                    root: &root)
        try installLocalPlugin(codexHome: codexHome, marketplaceName: marketplaceName,
                               pluginName: pluginName, sourcePath: sourcePath)
        enablePlugin(pluginKey: "\(pluginName)@\(marketplaceName)", root: &root)
        try writeUserConfigTOML(root, codexHome: codexHome)
        return .object([
            "authPolicy": .string("ON_USE"),
            "appsNeedingAuth": .array([]),
        ])
    }

    private static func pluginUninstallResponse(codexHome: String,
                                               params: JSONValue?) throws -> JSONValue {
        guard let pluginId = params?["pluginId"]?.stringValue,
              let (pluginName, marketplaceName) = parsePluginKey(pluginId) else {
            throw SimpleError("plugin/uninstall requires pluginId")
        }
        var root = try readUserConfigTOML(path: codexHome + "/config.toml")
        disablePlugin(pluginKey: pluginId, root: &root)
        try writeUserConfigTOML(root, codexHome: codexHome)
        let cachePath = pluginCacheRoot(codexHome: codexHome)
            + "/\(marketplaceName)/\(pluginName)"
        if FileManager.default.fileExists(atPath: cachePath) {
            try FileManager.default.removeItem(atPath: cachePath)
        }
        return .object([:])
    }

    private static func pluginShareSaveResponse(codexHome: String,
                                                params: JSONValue?) throws -> JSONValue {
        guard let pluginPath = params?["pluginPath"]?.stringValue else {
            throw SimpleError("plugin/share/save requires pluginPath")
        }
        let localPath = standardizedPath(pluginPath)
        guard let manifestPath = pluginManifestPath(localPath),
              let manifest = try readJSONObject(path: manifestPath),
              let pluginName = manifest["name"] as? String,
              isSafePluginSegment(pluginName) else {
            throw SimpleError("plugin/share/save requires a valid local plugin")
        }
        if let discoverability = params?["discoverability"]?.stringValue,
           discoverability == "LISTED" {
            throw SimpleError("discoverability LISTED is not supported for plugin/share/save; use UNLISTED or PRIVATE")
        }
        let targets = try parsePluginShareTargets(params?["shareTargets"])
        let discoverability = params?["discoverability"]?.stringValue ?? "PRIVATE"
        guard discoverability == "PRIVATE" || discoverability == "UNLISTED" else {
            throw SimpleError("plugin/share/save discoverability must be PRIVATE or UNLISTED")
        }
        var ledger = try pluginShareLedger(codexHome: codexHome)
        let requestedId = params?["remotePluginId"]?.stringValue
        if requestedId != nil && (params?["discoverability"] != nil || params?["shareTargets"] != nil) {
            throw SimpleError("discoverability and shareTargets are only supported when creating a plugin share; use plugin/share/updateTargets to update share settings")
        }
        let remotePluginId: String
        if let requestedId {
            guard isValidRemotePluginId(requestedId) else {
                throw SimpleError("invalid remote plugin id")
            }
            remotePluginId = requestedId
        } else if let existing = ledger.sharesByLocalPath[localPath] {
            remotePluginId = existing.remotePluginId
        } else {
            let data = "\(pluginName):\(localPath)".data(using: .utf8) ?? Data()
            remotePluginId = uniquePluginShareRemoteId(
                preferred: "rplg_\(stableDataHash(data))",
                ledger: ledger)
        }
        var entry = ledger.shares[remotePluginId] ?? PluginShareEntry(
            remotePluginId: remotePluginId, pluginName: pluginName, localPluginPath: localPath)
        entry.pluginName = pluginName
        entry.localPluginPath = localPath
        entry.remoteVersion = pluginManifestVersion(localPath)
        if requestedId == nil {
            entry.discoverability = discoverability
            entry.sharePrincipals = pluginSharePrincipals(targets: targets)
        }
        entry.shareUrl = "codex://plugin-share/\(remotePluginId)"
        entry.updatedAtMs = currentTimeMillis()
        ledger.shares[remotePluginId] = entry
        try writePluginShareLedger(ledger, codexHome: codexHome)
        return .object([
            "remotePluginId": .string(remotePluginId),
            "shareUrl": .string(entry.shareUrl),
        ])
    }

    private static func pluginShareUpdateTargetsResponse(codexHome: String,
                                                         params: JSONValue?) throws -> JSONValue {
        guard let remotePluginId = params?["remotePluginId"]?.stringValue,
              isValidRemotePluginId(remotePluginId) else {
            throw SimpleError("invalid remote plugin id")
        }
        guard let discoverability = params?["discoverability"]?.stringValue,
              discoverability == "PRIVATE" || discoverability == "UNLISTED" else {
            throw SimpleError("plugin/share/updateTargets discoverability must be PRIVATE or UNLISTED")
        }
        let targets = try parsePluginShareTargets(params?["shareTargets"] ?? .array([]))
        var ledger = try pluginShareLedger(codexHome: codexHome)
        guard var entry = ledger.shares[remotePluginId] else {
            throw SimpleError("plugin/share/updateTargets could not find remotePluginId")
        }
        entry.discoverability = discoverability
        entry.sharePrincipals = pluginSharePrincipals(targets: targets)
        entry.updatedAtMs = currentTimeMillis()
        ledger.shares[remotePluginId] = entry
        try writePluginShareLedger(ledger, codexHome: codexHome)
        return .object([
            "discoverability": .string(discoverability),
            "principals": .array(entry.sharePrincipals),
        ])
    }

    private static func pluginShareListResponse(codexHome: String) throws -> JSONValue {
        let ledger = try pluginShareLedger(codexHome: codexHome)
        let data: [JSONValue] = ledger.shares.values
            .sorted { $0.remotePluginId < $1.remotePluginId }
            .map { entry in
                .object([
                    "plugin": pluginShareSummaryJSON(entry),
                    "localPluginPath": .string(entry.localPluginPath),
                ])
            }
        return .object(["data": .array(data)])
    }

    private static func pluginShareCheckoutResponse(codexHome: String,
                                                   params: JSONValue?) throws -> JSONValue {
        guard let remotePluginId = params?["remotePluginId"]?.stringValue,
              isValidRemotePluginId(remotePluginId) else {
            throw SimpleError("invalid remote plugin id")
        }
        var ledger = try pluginShareLedger(codexHome: codexHome)
        guard var entry = ledger.shares[remotePluginId] else {
            throw SimpleError("plugin/share/checkout could not find remotePluginId")
        }
        guard FileManager.default.fileExists(atPath: entry.localPluginPath) else {
            throw SimpleError("plugin/share/checkout local plugin path no longer exists")
        }
        let checkoutRoot = codexHome + "/plugins/\(entry.pluginName)"
        if !FileManager.default.fileExists(atPath: checkoutRoot) {
            try FileManager.default.createDirectory(
                atPath: (checkoutRoot as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: entry.localPluginPath, toPath: checkoutRoot)
        }
        let marketplacePath = codexHome + "/.agents/plugins/marketplace.json"
        try updatePersonalPluginMarketplace(codexHome: codexHome, pluginName: entry.pluginName,
                                            pluginPath: checkoutRoot)
        entry.localPluginPath = checkoutRoot
        entry.updatedAtMs = currentTimeMillis()
        ledger.shares[remotePluginId] = entry
        try writePluginShareLedger(ledger, codexHome: codexHome)
        return .object([
            "remotePluginId": .string(remotePluginId),
            "pluginId": .string("\(entry.pluginName)@codex-curated"),
            "pluginName": .string(entry.pluginName),
            "pluginPath": .string(checkoutRoot),
            "marketplaceName": .string("codex-curated"),
            "marketplacePath": .string(marketplacePath),
            "remoteVersion": entry.remoteVersion.map(JSONValue.string) ?? .null,
        ])
    }

    private static func pluginShareDeleteResponse(codexHome: String,
                                                 params: JSONValue?) throws -> JSONValue {
        guard let remotePluginId = params?["remotePluginId"]?.stringValue,
              isValidRemotePluginId(remotePluginId) else {
            throw SimpleError("invalid remote plugin id")
        }
        var ledger = try pluginShareLedger(codexHome: codexHome)
        ledger.shares.removeValue(forKey: remotePluginId)
        try writePluginShareLedger(ledger, codexHome: codexHome)
        return .object([:])
    }

    private static func appsListResponse(codexHome: String,
                                         params: AppsListParams,
                                         runtimeFeatureEnablement: [String: Bool] = [:])
    throws -> AppsListResponse {
        let config = try readUserConfigTOML(path: codexHome + "/config.toml")
        if runtimeFeatureEnablement["apps"] == false {
            return AppsListResponse(data: [], nextCursor: nil)
        }
        let apps = ConnectorsDiscovery().discover(codexHome: codexHome)
            .map { connectorAppJSON($0, enabled: appEnabled($0.id, config: config)) }
        let start: Int
        if let cursor = params.cursor {
            guard let parsed = Int(cursor), parsed >= 0 else {
                throw SimpleError("invalid cursor: \(cursor)")
            }
            start = parsed
        } else {
            start = 0
        }
        guard start <= apps.count else {
            throw SimpleError("cursor \(start) exceeds total apps \(apps.count)")
        }
        let effectiveLimit: Int
        if let limit = params.limit {
            guard limit >= 0 else {
                throw SimpleError("app/list limit must be non-negative")
            }
            effectiveLimit = max(1, limit)
        } else {
            effectiveLimit = max(1, apps.count)
        }
        let end = min(apps.count, start + effectiveLimit)
        let data = Array(apps[start..<end])
        let nextCursor = end < apps.count ? String(end) : nil
        return AppsListResponse(data: data, nextCursor: nextCursor)
    }

    private static func connectorAppJSON(_ connector: ConnectorRecord,
                                         enabled: Bool) -> JSONValue {
        .object([
            "id": .string(connector.id),
            "name": .string(connector.name),
            "description": .string(connector.description),
            "logoUrl": connector.logoUrl.map(JSONValue.string) ?? .null,
            "logoUrlDark": connector.logoUrlDark.map(JSONValue.string) ?? .null,
            "distributionChannel": connector.distributionChannel.map(JSONValue.string) ?? .null,
            "branding": .null,
            "appMetadata": .null,
            "labels": connector.labels.map { .object($0.mapValues(JSONValue.string)) } ?? .null,
            "installUrl": connector.installUrl.map(JSONValue.string) ?? .null,
            "isAccessible": .bool(connector.isAccessible),
            "isEnabled": .bool(enabled),
            "pluginDisplayNames": .array(connector.pluginDisplayNames.map(JSONValue.string)),
        ])
    }

    private static func appEnabled(_ id: String,
                                   config: [String: ConfigValue]) -> Bool {
        guard case .object(let apps)? = config["apps"],
              case .object(let app)? = apps[id],
              case .bool(let enabled)? = app["enabled"] else {
            return true
        }
        return enabled
    }

    private static func resolveMarketplaceForPluginInstall(
        codexHome: String, params: JSONValue?, pluginName: String) throws -> (String, String) {
        if let path = params?["marketplacePath"]?.stringValue {
            let root = standardizedPath(path)
            guard let manifestPath = marketplaceManifestPath(root),
                  let manifest = try readJSONObject(path: manifestPath),
                  let name = manifest["name"] as? String,
                  isSafePluginSegment(name) else {
                throw SimpleError("plugin/install marketplacePath must contain a supported marketplace.json")
            }
            return (name, root)
        }
        let requestedName = params?["remoteMarketplaceName"]?.stringValue
        let config = try readUserConfigTOML(path: codexHome + "/config.toml")
        for root in configuredMarketplaceRoots(codexHome: codexHome, config: config) {
            guard let manifestPath = marketplaceManifestPath(root),
                  let manifest = try readJSONObject(path: manifestPath),
                  let name = manifest["name"] as? String,
                  requestedName == nil || requestedName == name else { continue }
            let entries = try marketplacePluginEntries(marketplaceRoot: root)
            if entries[pluginName] != nil { return (name, root) }
        }
        throw SimpleError("plugin/install could not resolve marketplace for \(pluginName)")
    }

    private static func configuredMarketplaceRoots(codexHome: String,
                                                   config: [String: ConfigValue]) -> [String] {
        guard case .object(let marketplaces)? = config["marketplaces"] else { return [] }
        return marketplaces.compactMap { name, value in
            guard isSafePluginSegment(name), case .object(let table) = value else { return nil }
            if case .string("local")? = table["source_type"],
               case .string(let source)? = table["source"] {
                return standardizedPath(source)
            }
            return standardizedPath(codexHome + "/.tmp/marketplaces/" + name)
        }
    }

    private static func pluginSummaryJSON(pluginKey: String,
                                          entry: MarketplacePluginEntry,
                                          installed: Bool,
                                          enabled: Bool,
                                          share: PluginShareEntry? = nil,
                                          rawPlugin: [String: Any]? = nil,
                                          pluginManifest: [String: Any]? = nil) -> JSONValue {
        let policy = rawPlugin?["policy"] as? [String: Any]
        let installPolicy = policy?["installation"] as? String ?? "AVAILABLE"
        let authPolicy = policy?["authentication"] as? String ?? "ON_INSTALL"
        return .object([
            "id": .string(pluginKey),
            "name": .string(entry.name),
            "installed": .bool(installed),
            "enabled": .bool(enabled),
            "authPolicy": .string(authPolicy),
            "installPolicy": .string(installPolicy),
            "availability": .string("AVAILABLE"),
            "source": entry.source,
            "interface": pluginInterfaceJSON(rawPlugin: rawPlugin,
                                             pluginManifest: pluginManifest),
            "keywords": .array(jsonStringArray(pluginManifest?["keywords"] as Any)
                .map(JSONValue.string)),
            "localVersion": entry.version.map(JSONValue.string) ?? .null,
            "remotePluginId": .null,
            "shareContext": share.map(pluginShareContextJSON) ?? .null,
        ])
    }

    private static func pluginInterfaceJSON(rawPlugin: [String: Any]?,
                                            pluginManifest: [String: Any]?) -> JSONValue {
        var object = (pluginManifest?["interface"] as? [String: Any]) ?? [:]
        if object["category"] == nil, let category = rawPlugin?["category"] as? String {
            object["category"] = category
        }
        return object.isEmpty ? .null : jsonAnyToValue(object)
    }

    private static func resolveMarketplaceReadPath(_ rawPath: String?) throws
        -> (manifestPath: String, root: String) {
        guard let rawPath else { throw SimpleError("plugin/read requires marketplacePath") }
        let path = standardizedPath(rawPath)
        if path.hasSuffix("/.agents/plugins/marketplace.json") {
            let root = String(path.dropLast("/.agents/plugins/marketplace.json".count))
            return (path, root.isEmpty ? "/" : root)
        }
        if path.hasSuffix("/.claude-plugin/marketplace.json") {
            let root = String(path.dropLast("/.claude-plugin/marketplace.json".count))
            return (path, root.isEmpty ? "/" : root)
        }
        guard let manifest = marketplaceManifestPath(path) else {
            throw SimpleError("plugin/read marketplacePath must contain a supported marketplace.json")
        }
        return (manifest, path)
    }

    private static func resolveMarketplaceReadPath(
        codexHome: String,
        config: [String: ConfigValue],
        marketplacePath: String?,
        remoteMarketplaceName: String?) throws -> (manifestPath: String, root: String) {
        if let marketplacePath {
            return try resolveMarketplaceReadPath(marketplacePath)
        }
        guard let remoteMarketplaceName, isSafePluginSegment(remoteMarketplaceName) else {
            throw SimpleError("plugin/read requires remoteMarketplaceName")
        }
        for root in configuredMarketplaceRoots(codexHome: codexHome, config: config) {
            guard let manifestPath = marketplaceManifestPath(root),
                  let manifest = try readJSONObject(path: manifestPath),
                  manifest["name"] as? String == remoteMarketplaceName else {
                continue
            }
            return (manifestPath, root)
        }
        throw SimpleError("remote plugin read is not enabled for marketplace \(remoteMarketplaceName)")
    }

    private static func pluginSkillSummaries(pluginRoot: String,
                                             pluginName: String,
                                             config: [String: ConfigValue]) -> [JSONValue] {
        let skillsRoot = standardizedPath(pluginRoot + "/skills")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: skillsRoot) else {
            return []
        }
        return names.sorted().compactMap { name in
            guard isSafePluginSegment(name) else { return nil }
            let path = skillsRoot + "/\(name)/SKILL.md"
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            let meta = skillFrontmatter(contents)
            let fullName = "\(pluginName):\(meta.name ?? name)"
            return .object([
                "name": .string(fullName),
                "description": .string(meta.description ?? ""),
                "shortDescription": .null,
                "interface": .null,
                "path": .string(path),
                "enabled": .bool(skillEnabled(fullName, config: config)),
            ])
        }
    }

    private static func skillFrontmatter(_ contents: String)
        -> (name: String?, description: String?) {
        guard contents.hasPrefix("---\n"),
              let end = contents.dropFirst(4).range(of: "\n---") else {
            return (nil, nil)
        }
        let yaml = contents[contents.index(contents.startIndex, offsetBy: 4)..<end.lowerBound]
        var name: String?
        var description: String?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch parts[0].trimmingCharacters(in: .whitespacesAndNewlines) {
            case "name": name = value
            case "description": description = value
            default: break
            }
        }
        return (name, description)
    }

    private static func skillEnabled(_ name: String,
                                     config: [String: ConfigValue]) -> Bool {
        let entries: [ConfigValue]
        if case .object(let skills)? = config["skills"],
           case .array(let configured)? = skills["config"] {
            entries = configured
        } else if case .array(let configured)? = config["skills"] {
            entries = configured
        } else {
            return true
        }
        for entry in entries {
            guard case .object(let object) = entry,
                  case .string(let configuredName)? = object["name"],
                  configuredName == name,
                  case .bool(let enabled)? = object["enabled"] else { continue }
            return enabled
        }
        return true
    }

    private static func pluginHookSummaries(pluginRoot: String,
                                            pluginKey: String) -> [JSONValue] {
        let path = pluginRoot + "/hooks/hooks.json"
        guard let object = try? readJSONObject(path: path),
              let hooks = object["hooks"] as? [String: Any] else { return [] }
        var out: [JSONValue] = []
        for event in hooks.keys.sorted() {
            let eventName = hookEventName(event)
            guard let groups = hooks[event] as? [Any] else { continue }
            for (groupIndex, rawGroup) in groups.enumerated() {
                guard let group = rawGroup as? [String: Any],
                      let values = group["hooks"] as? [Any] else { continue }
                for index in values.indices {
                    out.append(.object([
                        "key": .string("\(pluginKey):hooks/hooks.json:\(eventName):\(groupIndex):\(index)"),
                        "eventName": .string(eventName),
                    ]))
                }
            }
        }
        return out
    }

    private static func hookEventName(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let ch = Character(scalar)
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                result.append("_")
            }
            result.append(String(ch).lowercased())
        }
        return result
    }

    private static func pluginAppSummaries(pluginRoot: String) -> [JSONValue] {
        guard let object = try? readJSONObject(path: pluginRoot + "/.app.json"),
              let apps = object["apps"] as? [String: Any] else { return [] }
        return apps.keys.sorted().map { id in
            .object([
                "id": .string(id),
                "name": .string(id),
                "description": .null,
                "installUrl": .string("https://chatgpt.com/apps/\(id)/\(id)"),
                "needsAuth": .bool(true),
            ])
        }
    }

    private static func pluginMcpServerNames(pluginRoot: String) -> [String] {
        guard let object = try? readJSONObject(path: pluginRoot + "/.mcp.json"),
              let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted()
    }

    private static func pluginShareSummaryJSON(_ entry: PluginShareEntry) -> JSONValue {
        .object([
            "id": .string("\(entry.pluginName)@codex-curated"),
            "name": .string(entry.pluginName),
            "installed": .bool(FileManager.default.fileExists(atPath: entry.localPluginPath)),
            "enabled": .bool(true),
            "authPolicy": .string("ON_USE"),
            "installPolicy": .string("AVAILABLE"),
            "availability": .string("AVAILABLE"),
            "source": .object(["type": .string("local"), "path": .string(entry.localPluginPath)]),
            "interface": .null,
            "keywords": .array([]),
            "localVersion": entry.remoteVersion.map(JSONValue.string) ?? .null,
            "remotePluginId": .string(entry.remotePluginId),
            "shareContext": pluginShareContextJSON(entry),
        ])
    }

    private static func pluginShareContextJSON(_ entry: PluginShareEntry) -> JSONValue {
        .object([
            "remotePluginId": .string(entry.remotePluginId),
            "remoteVersion": entry.remoteVersion.map(JSONValue.string) ?? .null,
            "discoverability": .string(entry.discoverability),
            "shareUrl": .string(entry.shareUrl),
            "creatorAccountUserId": .string("local"),
            "creatorName": .string("Local"),
            "sharePrincipals": .array(entry.sharePrincipals),
        ])
    }

    private static func parsePluginShareTargets(_ value: JSONValue?) throws -> [JSONValue] {
        let rawTargets = value?.arrayValue ?? []
        for target in rawTargets {
            guard let principalType = target["principalType"]?.stringValue,
                  ["user", "group"].contains(principalType),
                  let principalId = target["principalId"]?.stringValue,
                  !principalId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let role = target["role"]?.stringValue,
                  ["reader", "editor"].contains(role) else {
                throw SimpleError("shareTargets must contain user or group principalType, principalId, and reader/editor role")
            }
        }
        return rawTargets
    }

    private static func pluginSharePrincipals(targets: [JSONValue]) -> [JSONValue] {
        var principals: [JSONValue] = [
            .object([
                "principalType": .string("user"),
                "principalId": .string("local"),
                "role": .string("owner"),
                "name": .string("Local"),
            ]),
        ]
        principals.append(contentsOf: targets.map { target in
            let principalId = target["principalId"]?.stringValue ?? ""
            return .object([
                "principalType": .string(target["principalType"]?.stringValue ?? "user"),
                "principalId": .string(principalId),
                "role": .string(target["role"]?.stringValue ?? "reader"),
                "name": .string(principalId),
            ])
        })
        return principals
    }

    private static func pluginShareLedger(codexHome: String) throws -> PluginShareLedger {
        let path = pluginShareLedgerPath(codexHome: codexHome)
        guard FileManager.default.fileExists(atPath: path) else { return PluginShareLedger() }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(PluginShareLedger.self, from: data)
        } catch {
            throw SimpleError("failed to parse plugin share ledger \(path): \(error.localizedDescription)")
        }
    }

    private static func writePluginShareLedger(_ ledger: PluginShareLedger,
                                               codexHome: String) throws {
        let path = pluginShareLedgerPath(codexHome: codexHome)
        if ledger.shares.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ledger)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func pluginShareLedgerPath(codexHome: String) -> String {
        codexHome + "/.tmp/plugin-share-local-paths-v1.json"
    }

    private static func uniquePluginShareRemoteId(preferred: String,
                                                  ledger: PluginShareLedger) -> String {
        if !ledger.shares.keys.contains(preferred) { return preferred }
        var idx = 2
        while ledger.shares.keys.contains("\(preferred)_\(idx)") {
            idx += 1
        }
        return "\(preferred)_\(idx)"
    }

    private static func isValidRemotePluginId(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z")
                || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_"
        }
    }

    private static func currentTimeMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func updatePersonalPluginMarketplace(codexHome: String,
                                                        pluginName: String,
                                                        pluginPath: String) throws {
        let marketplacePath = codexHome + "/.agents/plugins/marketplace.json"
        try FileManager.default.createDirectory(
            atPath: (marketplacePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var manifest = try readJSONObject(path: marketplacePath) ?? [
            "name": "codex-curated",
            "interface": ["displayName": "Personal"],
            "plugins": [],
        ]
        var plugins = (manifest["plugins"] as? [Any]) ?? []
        let relativePath = "./" + relativePath(pluginPath, root: codexHome)
        let entry: [String: Any] = [
            "name": pluginName,
            "source": ["source": "local", "path": relativePath],
            "policy": ["installation": "AVAILABLE", "authentication": "ON_USE"],
        ]
        if let index = plugins.firstIndex(where: {
            ($0 as? [String: Any])?["name"] as? String == pluginName
        }) {
            plugins[index] = entry
        } else {
            plugins.append(entry)
        }
        manifest["plugins"] = plugins
        let data = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: marketplacePath), options: .atomic)
    }

    private static func isPluginInstalled(codexHome: String,
                                          marketplaceName: String,
                                          pluginName: String) -> Bool {
        let base = pluginCacheRoot(codexHome: codexHome)
            + "/\(marketplaceName)/\(pluginName)"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base, isDirectory: &isDir),
              isDir.boolValue,
              let children = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            return false
        }
        return children.contains { child in
            var childIsDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: base + "/" + child,
                                                  isDirectory: &childIsDir)
                && childIsDir.boolValue && isSafePluginVersion(child)
        }
    }

    private struct FuzzyMatch {
        var root: String
        var path: String
        var isDirectory: Bool
        var score: Int
        var indices: [Int]
        var fileName: String {
            URL(fileURLWithPath: path).lastPathComponent
        }
        var json: JSONValue {
            .object([
                "root": .string(root),
                "path": .string(path),
                "match_type": .string(isDirectory ? "directory" : "file"),
                "file_name": .string(fileName),
                "score": .int(Int64(score)),
                "indices": .array(indices.map { .int(Int64($0)) }),
            ])
        }
    }

    private static func runFuzzyFileSearch(query: String, roots: [String]) -> [JSONValue] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var matches: [FuzzyMatch] = []
        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                let rel = relativePath(url.path, root: root)
                if rel.isEmpty { continue }
                guard let indices = fuzzyIndices(query: query, candidate: rel) else { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let score = fuzzyScore(query: query, candidate: rel, indices: indices)
                matches.append(FuzzyMatch(root: root, path: rel,
                                          isDirectory: values?.isDirectory == true,
                                          score: score, indices: indices))
            }
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.path < $1.path
        }
        return matches.prefix(20).map(\.json)
    }

    private static func relativePath(_ path: String, root: String) -> String {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        let rootParts = rootURL.pathComponents
        let pathParts = pathURL.pathComponents
        guard pathParts.count >= rootParts.count,
              pathParts.prefix(rootParts.count) == rootParts[...] else {
            return pathURL.lastPathComponent
        }
        return pathParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    private static func fuzzyIndices(query: String, candidate: String) -> [Int]? {
        let q = Array(query.lowercased())
        if q.isEmpty { return [] }
        let c = Array(candidate.lowercased())
        var qi = 0
        var indices: [Int] = []
        for (idx, ch) in c.enumerated() where qi < q.count {
            if ch == q[qi] {
                indices.append(idx)
                qi += 1
            }
        }
        return qi == q.count ? indices : nil
    }

    private static func fuzzyScore(query: String, candidate: String, indices: [Int]) -> Int {
        guard let first = indices.first, let last = indices.last else { return 0 }
        let span = last - first + 1
        let consecutiveBonus = span == indices.count ? 40 : 0
        let basename = URL(fileURLWithPath: candidate).lastPathComponent.lowercased()
        let prefixBonus = basename.hasPrefix(query.lowercased()) ? 30 : 0
        let compactness = max(0, 30 - (span - indices.count) * 3)
        return 50 + consecutiveBonus + prefixBonus + compactness - min(first, 20)
    }

    private func handleSkillsConfigWriteRequest(id: RequestId, method: String,
                                                params: JSONValue?,
                                                conn: any ClientConnection) async -> Bool {
        guard method == "skills/config/write" else { return false }
        guard let params else {
            await conn.send(WireError.invalidRequest(id: id, "skills/config/write requires params"))
            return true
        }
        let path = params["path"]?.stringValue
        let name = params["name"]?.stringValue
        guard let enabled = params["enabled"]?.boolValue else {
            await conn.send(WireError.invalidRequest(
                id: id, "skills/config/write requires enabled"))
            return true
        }
        let hasPath = path?.isEmpty == false
        let hasName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasPath != hasName else {
            await conn.send(WireError.invalidRequest(
                id: id, "skills/config/write requires exactly one of path or name"))
            return true
        }
        if let path, hasPath, !path.hasPrefix("/") {
            await conn.send(WireError.invalidRequest(
                id: id, "skills/config/write path must be absolute"))
            return true
        }

        do {
            let loader = ConfigLoader(codexHome: codexHome)
            var root = try Self.readUserConfigTOML(path: loader.tomlPath)
            let changed = try Self.applySkillConfigWrite(
                root: &root, path: path, name: name, enabled: enabled)
            if changed {
                try loader.persistTOML(root)
            }
            await reply(conn, id, .object(["effectiveEnabled": .bool(enabled)]))
            await conn.send(ServerNotification.skillsChanged.toMessage())
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private func handleConfigWriteRequest(id: RequestId, method: String,
                                          params: JSONValue?,
                                          conn: any ClientConnection) async -> Bool {
        guard method == "config/value/write" || method == "config/batchWrite" else {
            return false
        }
        guard let params else {
            await conn.send(WireError.invalidRequest(id: id, "\(method) requires params"))
            return true
        }

        let edits: [(String, JSONValue, String)]
        if method == "config/value/write" {
            guard let keyPath = params["keyPath"]?.stringValue,
                  let value = params["value"],
                  let strategy = params["mergeStrategy"]?.stringValue else {
                await conn.send(WireError.invalidRequest(
                    id: id, "config/value/write requires keyPath, value, and mergeStrategy"))
                return true
            }
            edits = [(keyPath, value, strategy)]
        } else {
            guard let editValues = params["edits"]?.arrayValue else {
                await conn.send(WireError.invalidRequest(id: id, "config/batchWrite requires edits"))
                return true
            }
            var collected: [(String, JSONValue, String)] = []
            for edit in editValues {
                guard let keyPath = edit["keyPath"]?.stringValue,
                      let value = edit["value"],
                      let strategy = edit["mergeStrategy"]?.stringValue else {
                    await conn.send(WireError.invalidRequest(
                        id: id, "config/batchWrite edits require keyPath, value, and mergeStrategy"))
                    return true
                }
                collected.append((keyPath, value, strategy))
            }
            edits = collected
        }

        let loader = ConfigLoader(codexHome: codexHome)
        let configPath = URL(fileURLWithPath: loader.tomlPath).standardizedFileURL.path
        if let requested = params["filePath"]?.stringValue {
            let requestedPath = URL(fileURLWithPath: requested).standardizedFileURL.path
            guard requestedPath == configPath else {
                // Writes are only permitted to the user layer; any other target
                // is a read-only layer (upstream `ConfigLayerReadonly`).
                await conn.send(WireError.configWriteError(
                    id: id, code: "configLayerReadonly",
                    "Only writes to the user config are allowed"))
                return true
            }
        }
        // `expectedVersion` is compared against the USER layer's version — the
        // same `sha256:<hex>` value `config/read` reports for that layer — so a
        // read→write round-trip matches (upstream uses the active user layer's
        // `version_for_toml`).
        if let expected = params["expectedVersion"]?.stringValue,
           expected != Self.userLayerVersion(codexHome: codexHome) {
            await conn.send(WireError.configWriteError(
                id: id, code: "configVersionConflict",
                "Configuration was modified since last read. Fetch latest version and retry."))
            return true
        }

        do {
            var root = try Self.readUserConfigTOML(path: configPath)
            var changed = false
            var editedKeyPaths: [String] = []
            for (keyPath, value, strategy) in edits {
                let segments = try Self.parseConfigKeyPath(keyPath)
                editedKeyPaths.append(keyPath)
                let configValue = Self.configValue(from: value)
                changed = try Self.applyConfigEdit(
                    root: &root, segments: segments, value: configValue,
                    mergeStrategy: strategy) || changed
            }
            // Upstream rejects writes whose resulting config would fail
            // `try_into::<ConfigToml>()`: `validate_config(&user_config)` is run
            // on the post-edit user config (config_manager_service.rs:274-279).
            // A wrong scalar type or an invalid enum variant maps to
            // `ConfigValidationError`. Mirror that by type/enum-checking the
            // post-edit user root BEFORE persisting. (Upstream additionally
            // validates the effective merged config; the only user-controlled
            // input on this path is the user layer, which we validate here.)
            try Self.validateConfigToml(root)
            if changed {
                try loader.persistTOML(root)
            }
            // Detect whether a higher-precedence layer (system/mdm/project)
            // overrides any edited key after the write. Upstream returns
            // `okOverridden` + `overriddenMetadata` in that case so the client
            // knows its user-layer write is shadowed (config write
            // `first_overridden_edit`).
            let overridden = Self.firstOverriddenEdit(
                codexHome: codexHome, editedKeyPaths: editedKeyPaths)
            // `config/batchWrite` carries an optional `reloadUserConfig` flag
            // (v2/config.rs:692-694). Upstream's single-process app-server hot-
            // reloads the user-config layer into every in-process thread
            // (config_processor.rs:308-310 → Session::reload_user_config_layer).
            // In this port each thread runs as a SEPARATE `codex-session`
            // worker process that loads config.toml fresh at spawn, so a
            // worker's running turn loop owns its own immutable config snapshot
            // and there is no in-process reference to hot-swap. Threads started
            // AFTER this write already observe the new config (they re-read
            // config.toml at spawn). Pushing a mid-session reload would require
            // a new cross-process `EngineOp` and worker-side between-turn apply;
            // that is the documented multi-process divergence (see audit
            // finding "config/batchWrite reloadUserConfig flag ignored"). We
            // read the flag so it is acknowledged rather than silently dropped.
            // No-op for already-running worker processes (divergence above);
            // newly spawned workers pick up the persisted config.
            let _reloadRequested = method == "config/batchWrite"
                && params["reloadUserConfig"]?.boolValue == true
            _ = _reloadRequested
            await reply(conn, id, .object([
                "status": .string(overridden == nil ? "ok" : "okOverridden"),
                "version": .string(Self.userLayerVersion(codexHome: codexHome)),
                "filePath": .string(configPath),
                "overriddenMetadata": overridden ?? .null,
            ]))
        } catch {
            // Parse/apply failures map to a validation error (upstream
            // `ConfigValidationError`).
            await conn.send(WireError.configWriteError(
                id: id, code: "configValidationError", error.localizedDescription))
        }
        return true
    }

    /// Upstream `first_overridden_edit`: after a user-layer write, reload the
    /// full config stack and return `OverriddenMetadata` for the first edited
    /// key whose effective value now comes from a higher-precedence (non-user)
    /// layer. Returns nil when the user write is the effective value.
    static func firstOverriddenEdit(codexHome: String,
                                    editedKeyPaths: [String],
                                    loader: ConfigLoader? = nil) -> JSONValue? {
        let cfg = (loader ?? ConfigLoader(codexHome: codexHome)).load()
        for keyPath in editedKeyPaths {
            // Effective layer = highest-precedence layer that provides a value
            // at this path (subtree-aware, mirrors upstream `find_effective_layer`).
            guard let meta = Self.effectiveLayerMeta(cfg, path: keyPath) else { continue }
            if case .user = meta.name { continue }   // user write is effective
            // Audit app-server-registry/finding-4: upstream
            // `compute_override_metadata` (config_manager_service.rs:605-607)
            // returns None when `user_value.is_some() && user_value ==
            // effective_value` — i.e. when the highest-precedence layer carries
            // the IDENTICAL value the user just wrote, the status stays `ok`
            // (no override report). Keying solely on layer identity would
            // mis-report a no-op-equivalent write as `okOverridden`. So before
            // reporting, compare the active user-layer value at this path
            // against the effective value and suppress the override when equal.
            let effectiveValue = cfg.value(keyPath)
            let userLayerValue: ConfigValue? = cfg.layers.first(where: {
                if case .user = $0.source { return true } else { return false }
            }).flatMap { Self.layerValueAtPath($0.values, path: keyPath) }
            if let uv = userLayerValue, uv == effectiveValue { continue }
            // A higher-precedence (system/mdm/project/…) layer shadows the write.
            let effective = effectiveValue.map(Self.configValueToJSON) ?? .null
            return .object([
                "message": .string(Self.overrideMessage(meta.name)),
                "overridingLayer": Self.configValueToJSON(meta.toJSON()),
                "effectiveValue": effective,
            ])
        }
        return nil
    }

    /// Upstream `override_message` (config_manager_service.rs:566-592): the
    /// human-readable `OverriddenMetadata.message` text, distinct per overriding
    /// layer type, embedding the domain/file path where upstream does. Reproduce
    /// the exact strings so frontends that surface or match on the message see
    /// the same text codex-rs emits.
    static func overrideMessage(_ layer: ConfigLayerSource) -> String {
        switch layer {
        case .mdm(let domain, _):
            return "Overridden by managed policy (MDM): \(domain)"
        case .system(let file):
            return "Overridden by managed config (system): \(file)"
        case .project(let dotCodexFolder):
            return "Overridden by project config: \(dotCodexFolder)/config.toml"
        case .sessionFlags:
            return "Overridden by session flags"
        case .user(let file, _):
            return "Overridden by user config: \(file)"
        case .legacyManagedConfigTomlFromFile(let file):
            return "Overridden by legacy managed_config.toml: \(file)"
        case .legacyManagedConfigTomlFromMdm:
            return "Overridden by legacy managed configuration from MDM"
        }
    }

    /// Version (`sha256:<hex>`) of the active user layer (`$CODEX_HOME/config.toml`).
    ///
    /// Upstream computes the user layer's version via `version_for_toml` over
    /// the RAW on-disk TOML value the user layer was loaded from
    /// (`config/src/state.rs:107-117` via `load_user_config_layer`,
    /// `loader/mod.rs:386-414`) — profiles intact, with no inline-profile
    /// overlay folded in. The bytes actually read/written by config write are
    /// that same raw file, so we must hash the raw root (not the `"toml"`
    /// config layer, which has profiles stripped/overlaid for the projection
    /// view). This keeps the `expectedVersion` round-trip in lock-step with the
    /// on-disk file.
    static func userLayerVersion(codexHome: String) -> String {
        let loader = ConfigLoader(codexHome: codexHome)
        let raw = (try? Self.readUserConfigTOML(path: loader.tomlPath)) ?? [:]
        return ConfigCanonicalVersion.version(of: raw)
    }

    /// Compute a config layer's `version` over the RAW on-disk TOML it was
    /// loaded from (upstream `version_for_toml` in `ConfigLayerEntry::new`),
    /// falling back to the in-memory layer values for non-file-backed sources
    /// (MDM/session-flags) which upstream also hashes from their raw value.
    static func rawLayerVersion(source: ConfigLayerSource,
                                fallback: [String: ConfigValue]) -> String {
        let file: String?
        switch source {
        case .user(let f, _): file = f
        case .system(let f): file = f
        // Project layers: upstream builds the `ConfigLayerEntry` from the
        // config AFTER `sanitize_project_config` (denylist removal),
        // relative-path resolution and alias normalization, then hashes THAT
        // via `version_for_toml` (loader/mod.rs:1203-1225, state.rs:107-117).
        // So the reported version must be over the sanitized+normalized layer
        // values (`fallback`), NOT the raw on-disk file (which would still
        // carry denylisted keys / legacy aliases). Re-reading the raw file
        // here would diverge from upstream whenever the project config.toml
        // sets a denylisted key. Hash the in-memory layer values instead.
        case .project: file = nil
        case .legacyManagedConfigTomlFromFile(let f): file = f
        case .mdm, .sessionFlags, .legacyManagedConfigTomlFromMdm: file = nil
        }
        if let file {
            let raw = (try? Self.readUserConfigTOML(path: file)) ?? [:]
            return ConfigCanonicalVersion.version(of: raw)
        }
        return ConfigCanonicalVersion.version(of: fallback)
    }

    /// Upstream `find_effective_layer`: the highest-precedence layer (by
    /// `ConfigLayerSource.precedence`) that provides a value at `path`
    /// (matching tables/arrays, not just scalars). Synthetic defaults excluded.
    static func effectiveLayerMeta(_ cfg: Config, path: String) -> ConfigLayerMetadata? {
        let candidates: [ConfigLayerMetadata] = cfg.layers.compactMap { layer in
            guard let src = layer.source,
                  Self.layerValueAtPath(layer.values, path: path) != nil else { return nil }
            return ConfigLayerMetadata(
                name: src, version: Self.rawLayerVersion(source: src, fallback: layer.values))
        }
        return candidates.max(by: { $0.name.precedence < $1.name.precedence })
    }

    /// Dotted-path lookup within a single layer's values (subtree-aware).
    static func layerValueAtPath(_ values: [String: ConfigValue], path: String) -> ConfigValue? {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        var cur: ConfigValue? = values[first]
        for p in parts.dropFirst() {
            guard case .object(let o)? = cur else { return nil }
            cur = o[p]
        }
        return cur
    }

    private func handleExternalAgentConfigRequest(id: RequestId, method: String,
                                                  params: JSONValue?,
                                                  conn: any ClientConnection) async -> Bool {
        guard method == "externalAgentConfig/detect"
                || method == "externalAgentConfig/import" else {
            return false
        }
        do {
            switch method {
            case "externalAgentConfig/detect":
                let items = try Self.detectExternalAgentConfig(codexHome: codexHome,
                                                               params: params)
                await reply(conn, id, .object(["items": .array(items)]))
            case "externalAgentConfig/import":
                let items = try Self.externalAgentMigrationItems(from: params)
                try await importExternalAgentConfig(items: items)
                await reply(conn, id, .object([:]))
                if !items.isEmpty {
                    await conn.send(ServerNotification.raw(
                        method: "externalAgentConfig/import/completed",
                        params: .object([:])).toMessage())
                }
            default:
                break
            }
        } catch {
            await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
        }
        return true
    }

    private static func readUserConfigTOML(path: String) throws -> [String: ConfigValue] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return try TOML.parse(text)
    }

    /// Mirror of upstream `validate_config` (config_manager_service.rs:539-542),
    /// which performs `let _: ConfigToml = value.clone().try_into()?;`. A
    /// strict serde deserialize into `ConfigToml` rejects:
    ///   - wrong scalar types (e.g. `model = 123`, `project_doc_max_bytes = "x"`)
    ///   - unknown enum variants (e.g. `approval_policy = "bogus"`,
    ///     `sandbox_mode = "full-write"`)
    /// Rather than porting the full `ConfigToml` struct, this validates the
    /// enum-valued keys against upstream's allowed variants and the typed
    /// scalar fields against their expected JSON type, throwing on the first
    /// violation. The caller maps any thrown error to `configValidationError`.
    static func validateConfigToml(_ root: [String: ConfigValue]) throws {
        // Strict type predicates: upstream's serde deserialize into `ConfigToml`
        // does NOT coerce across types (a string is not a valid `i64`/`bool`),
        // so these match the exact JSON kind rather than using the lenient
        // `ConfigValue` accessors.
        func isNullV(_ v: ConfigValue) -> Bool { if case .null = v { return true }; return false }
        func strictString(_ v: ConfigValue) -> String? { if case .string(let s) = v { return s }; return nil }
        func strictInt(_ v: ConfigValue) -> Bool {
            switch v { case .int, .double: return true; default: return false }
        }
        func strictBool(_ v: ConfigValue) -> Bool { if case .bool = v { return true }; return false }

        // Enum-valued keys: value (when present and non-null) must be one of
        // the listed serde variants.
        let enumKeys: [(String, Set<String>)] = [
            ("sandbox_mode", ["read-only", "workspace-write", "danger-full-access"]),
            ("model_reasoning_effort", ["none", "minimal", "low", "medium", "high", "xhigh"]),
            ("model_reasoning_summary", ["auto", "concise", "detailed", "none"]),
            ("model_verbosity", ["low", "medium", "high"]),
            ("cli_auth_credentials_store", ["file", "keyring", "auto", "ephemeral"]),
            ("mcp_oauth_credentials_store", ["auto", "file", "keyring"]),
            ("forced_login_method", ["chatgpt", "api"]),
            // WebSearchMode (config_types.rs:289-294).
            ("web_search", ["disabled", "cached", "live"]),
            // Personality (config_types.rs:278-282).
            ("personality", ["none", "friendly", "pragmatic"]),
            // plan_mode_reasoning_effort: ReasoningEffort (openai_models.rs:44-52).
            ("plan_mode_reasoning_effort",
             ["none", "minimal", "low", "medium", "high", "xhigh"]),
        ]
        for (key, allowed) in enumKeys {
            guard let v = root[key], !isNullV(v) else { continue }
            guard let s = strictString(v) else {
                throw SimpleError("Invalid configuration: `\(key)` must be a string")
            }
            if !allowed.contains(s) {
                throw SimpleError("Invalid configuration: unknown variant `\(s)` for `\(key)`")
            }
        }
        // `approval_policy` (AskForApproval): kebab-case unit variant string or
        // a `{ type = "granular", ... }` table (externally-untagged struct
        // variant).
        if let ap = root["approval_policy"], !isNullV(ap) {
            switch ap {
            case .string(let s):
                let allowed: Set<String> = ["untrusted", "on-failure", "on-request", "never"]
                if !allowed.contains(s) {
                    throw SimpleError("Invalid configuration: unknown variant `\(s)` for `approval_policy`")
                }
            case .object:
                break  // granular config table
            default:
                throw SimpleError("Invalid configuration: `approval_policy` must be a string or table")
            }
        }
        // Typed scalar fields: each must be the listed JSON type when present
        // and non-null.
        let stringFields = [
            "model", "review_model", "model_provider", "default_permissions",
            "instructions", "developer_instructions", "compact_prompt",
            "mcp_oauth_callback_url", "service_tier", "chatgpt_base_url",
            "apps_mcp_product_sku", "openai_base_url", "oss_provider", "profile",
        ]
        for key in stringFields {
            guard let v = root[key], !isNullV(v) else { continue }
            if strictString(v) == nil {
                throw SimpleError("Invalid configuration: `\(key)` must be a string")
            }
        }
        let intFields = [
            "model_context_window", "model_auto_compact_token_limit",
            "project_doc_max_bytes", "tool_output_token_limit",
            "background_terminal_max_timeout", "mcp_oauth_callback_port",
        ]
        for key in intFields {
            guard let v = root[key], !isNullV(v) else { continue }
            if !strictInt(v) {
                throw SimpleError("Invalid configuration: `\(key)` must be an integer")
            }
        }
        let boolFields = [
            "allow_login_shell", "include_permissions_instructions",
            "include_apps_instructions", "include_collaboration_mode_instructions",
            "include_environment_context", "hide_agent_reasoning",
            "show_raw_agent_reasoning", "model_supports_reasoning_summaries",
            "suppress_unstable_features_warning", "check_for_update_on_startup",
            "disable_paste_burst", "experimental_use_unified_exec_tool",
        ]
        for key in boolFields {
            guard let v = root[key], !isNullV(v) else { continue }
            if !strictBool(v) {
                throw SimpleError("Invalid configuration: `\(key)` must be a boolean")
            }
        }
        // `notify` / `project_doc_fallback_filenames`: arrays of strings.
        for key in ["notify", "project_doc_fallback_filenames"] {
            guard let v = root[key], !isNullV(v) else { continue }
            guard case .array(let arr) = v else {
                throw SimpleError("Invalid configuration: `\(key)` must be an array of strings")
            }
            if arr.contains(where: { strictString($0) == nil }) {
                throw SimpleError("Invalid configuration: `\(key)` must be an array of strings")
            }
        }
        // Nested objects with their own enum/typed leaves.
        if let history = root["history"], !isNullV(history) {
            guard case .object(let h) = history else {
                throw SimpleError("Invalid configuration: `history` must be a table")
            }
            if let p = h["persistence"], !isNullV(p) {
                guard let s = strictString(p), ["save-all", "none"].contains(s) else {
                    throw SimpleError("Invalid configuration: unknown variant for `history.persistence`")
                }
            }
            if let mb = h["max_bytes"], !isNullV(mb), !strictInt(mb) {
                throw SimpleError("Invalid configuration: `history.max_bytes` must be an integer")
            }
        }
        if let sep = root["shell_environment_policy"], !isNullV(sep) {
            guard case .object(let s) = sep else {
                throw SimpleError("Invalid configuration: `shell_environment_policy` must be a table")
            }
            if let inh = s["inherit"], !isNullV(inh) {
                guard let str = strictString(inh), ["core", "all", "none"].contains(str) else {
                    throw SimpleError("Invalid configuration: unknown variant for `shell_environment_policy.inherit`")
                }
            }
        }
    }

    private static func applySkillConfigWrite(root: inout [String: ConfigValue],
                                             path: String?,
                                             name: String?,
                                             enabled: Bool) throws -> Bool {
        var skills: [String: ConfigValue]
        if case .object(let existing)? = root["skills"] {
            skills = existing
        } else if root["skills"] == nil {
            skills = [:]
        } else {
            throw SimpleError("skills config must be a table")
        }

        var entries: [ConfigValue]
        if case .array(let existing)? = skills["config"] {
            entries = existing
        } else if skills["config"] == nil {
            entries = []
        } else {
            throw SimpleError("skills.config must be an array")
        }

        let selectorKey: String
        let selectorValue: String
        if let path, !path.isEmpty {
            selectorKey = "path"
            selectorValue = URL(fileURLWithPath: path).standardizedFileURL.path
        } else if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty {
            selectorKey = "name"
            selectorValue = name
        } else {
            throw SimpleError("skills/config/write requires exactly one of path or name")
        }

        let next = ConfigValue.object([
            selectorKey: .string(selectorValue),
            "enabled": .bool(enabled),
        ])
        var replaced = false
        var changed = false
        for i in entries.indices {
            guard case .object(let entry) = entries[i],
                  case .string(let existing)? = entry[selectorKey],
                  existing == selectorValue else {
                continue
            }
            replaced = true
            if entries[i] != next {
                entries[i] = next
                changed = true
            }
            break
        }
        if !replaced {
            entries.append(next)
            changed = true
        }

        skills["config"] = .array(entries)
        let nextSkills = ConfigValue.object(skills)
        if root["skills"] != nextSkills {
            root["skills"] = nextSkills
            changed = true
        }
        return changed
    }

    private static func configValue(from value: JSONValue) -> ConfigValue? {
        switch value {
        case .null: return nil
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a):
            return .array(a.map { configValue(from: $0) ?? .null })
        case .object(let o):
            return .object(o.mapValues { configValue(from: $0) ?? .null })
        }
    }

    /// Parse a `config/value/write` keyPath into segments, mirroring upstream
    /// `parse_key_path` EXACTLY (config_manager_service.rs:402-410): reject only
    /// fully empty/whitespace input, otherwise plain `split('.')`. Quotes and
    /// backslashes are LITERAL characters (no special parsing), and empty
    /// segments are NOT rejected — `a..b` yields `["a", "", "b"]`. This keeps
    /// the wire-facing keyPath round-trip in lock-step with upstream rather than
    /// imposing a stricter (divergent) quote/escape mini-parser.
    private static func parseConfigKeyPath(_ path: String) throws -> [String] {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimpleError("keyPath must not be empty")
        }
        return path.components(separatedBy: ".")
    }

    private static func applyConfigEdit(root: inout [String: ConfigValue],
                                        segments: [String],
                                        value: ConfigValue?,
                                        mergeStrategy: String) throws -> Bool {
        guard mergeStrategy == "replace" || mergeStrategy == "upsert" else {
            throw SimpleError("unsupported mergeStrategy \(mergeStrategy)")
        }
        guard let first = segments.first else { throw SimpleError("keyPath must not be empty") }
        if segments.count == 1 {
            let old = root[first]
            if let value {
                if mergeStrategy == "upsert",
                   case .object(let existing)? = old,
                   case .object(let overlay) = value {
                    let merged = configDeepMerge(.object(existing), .object(overlay))
                    root[first] = merged
                    return old != merged
                }
                root[first] = value
                return old != value
            } else {
                root.removeValue(forKey: first)
                return old != nil
            }
        }
        var current = root[first] ?? .object([:])
        let changed = try applyConfigEdit(
            value: &current, segments: Array(segments.dropFirst()),
            newValue: value, mergeStrategy: mergeStrategy)
        root[first] = current
        return changed
    }

    private static func applyConfigEdit(value current: inout ConfigValue,
                                        segments: [String],
                                        newValue: ConfigValue?,
                                        mergeStrategy: String) throws -> Bool {
        guard let first = segments.first else { throw SimpleError("keyPath must not be empty") }
        var object: [String: ConfigValue]
        if case .object(let existing) = current {
            object = existing
        } else {
            object = [:]
        }
        if segments.count == 1 {
            let old = object[first]
            if let newValue {
                if mergeStrategy == "upsert",
                   case .object(let existing)? = old,
                   case .object(let overlay) = newValue {
                    let merged = configDeepMerge(.object(existing), .object(overlay))
                    object[first] = merged
                    current = .object(object)
                    return old != merged
                }
                object[first] = newValue
                current = .object(object)
                return old != newValue
            } else {
                object.removeValue(forKey: first)
                current = .object(object)
                return old != nil
            }
        }
        var child = object[first] ?? .object([:])
        let changed = try applyConfigEdit(
            value: &child, segments: Array(segments.dropFirst()),
            newValue: newValue, mergeStrategy: mergeStrategy)
        object[first] = child
        current = .object(object)
        return changed
    }

    private static func configDeepMerge(_ base: ConfigValue?,
                                        _ overlay: ConfigValue) -> ConfigValue {
        guard case .object(let b)? = base, case .object(let o) = overlay else {
            return overlay
        }
        var out = b
        for (key, value) in o {
            out[key] = configDeepMerge(out[key], value)
        }
        return .object(out)
    }

    private static func configVersion(path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "0"
        }
        let modified = milliseconds(attrs[.modificationDate] as? Date)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return "\(modified)-\(size)"
    }

    private struct ExternalAgentMigrationItem {
        var itemType: String
        var cwd: String?
        var details: JSONValue?
    }

    private struct ExternalAgentSessionCandidate {
        var path: String
        var cwd: String
        var title: String?
        var version: String
        var messages: [(role: String, text: String)]
    }

    private struct ExternalAgentPluginGroup {
        var marketplaceName: String
        var pluginNames: [String]
        var marketplaceRoot: String?
    }

    private struct MarketplacePluginEntry {
        var name: String
        var source: JSONValue
        var sourcePath: String?
        var version: String?
    }

    private struct PluginShareLedger: Codable {
        var shares: [String: PluginShareEntry] = [:]

        var sharesByLocalPath: [String: PluginShareEntry] {
            shares.values.sorted { $0.remotePluginId < $1.remotePluginId }
                .reduce(into: [:]) { out, entry in
                    out[entry.localPluginPath] = entry
                }
        }
    }

    private struct PluginShareEntry: Codable {
        var remotePluginId: String
        var pluginName: String
        var localPluginPath: String
        var remoteVersion: String?
        var discoverability: String = "PRIVATE"
        var shareUrl: String = ""
        var sharePrincipals: [JSONValue] = []
        var updatedAtMs: Int64 = RequestRouter.currentTimeMillis()
    }

    private struct ExternalAgentSessionLedger: Codable {
        struct Entry: Codable {
            var threadId: String
            var version: String
        }
        var imported: [String: Entry] = [:]
    }

    private struct ParsedExternalAgentDocument {
        var frontmatter: [String: String]
        var body: String
        var hasFrontmatterError: Bool
    }

    private static func detectExternalAgentConfig(codexHome: String,
                                                  params: JSONValue?) throws -> [JSONValue] {
        let includeHome = params?["includeHome"]?.boolValue ?? false
        let cwds = params?["cwds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var items: [JSONValue] = []
        if includeHome {
            try detectExternalAgentScope(codexHome: codexHome, cwd: nil, into: &items)
        }
        for cwd in cwds {
            let repo = findRepoRoot(startingAt: cwd) ?? standardizedPath(cwd)
            try detectExternalAgentScope(codexHome: codexHome, cwd: repo, into: &items)
        }
        return items
    }

    private static func detectExternalAgentScope(codexHome: String,
                                                 cwd: String?,
                                                 into items: inout [JSONValue]) throws {
        let sourceRoot = externalAgentSourceRoot(codexHome: codexHome, cwd: cwd)
        let targetRoot = externalAgentTargetRoot(codexHome: codexHome, cwd: cwd)
        let sourceSettings = sourceRoot + "/settings.json"
        let targetConfig = targetRoot + "/config.toml"
        if let migrated = try migratedExternalAgentConfig(settingsPath: sourceSettings),
           !migrated.isEmpty,
           try configMergeWouldChange(existingPath: targetConfig, incoming: migrated) {
            items.append(externalAgentItem(
                itemType: "CONFIG",
                description: "Migrate \(sourceSettings) into \(targetConfig)",
                cwd: cwd,
                details: nil))
        }

        if let migrated = try migratedExternalAgentMcpConfig(codexHome: codexHome, cwd: cwd),
           !migrated.isEmpty,
           try configMergeWouldChange(existingPath: targetConfig, incoming: migrated) {
            items.append(externalAgentItem(
                itemType: "MCP_SERVER_CONFIG",
                description: "Migrate MCP servers from \(externalAgentMcpSourceRoot(codexHome: codexHome, cwd: cwd)) into \(targetConfig)",
                cwd: cwd,
                details: .object(["mcpServers": .array(migratedMcpServerNames(migrated)
                    .map { .object(["name": .string($0)]) })])))
        }

        let targetHooks = targetRoot + "/hooks.json"
        let hooks = try migratedExternalAgentHooks(sourceRoot: sourceRoot, targetRoot: targetRoot)
        if !hooks.isEmpty, isMissingOrEmptyTextFile(targetHooks) {
            items.append(externalAgentItem(
                itemType: "HOOKS",
                description: "Migrate hooks from \(sourceRoot) to \(targetHooks)",
                cwd: cwd,
                details: .object(["hooks": .array(Array(Set(hooks.compactMap { $0["event"]?.stringValue }))
                    .sorted().map { .object(["name": .string($0)]) })])))
        }

        let sourceSkills = sourceRoot + "/skills"
        let targetSkills = externalAgentTargetSkillsRoot(codexHome: codexHome, cwd: cwd)
        if try !missingChildDirectoryNames(source: sourceSkills, target: targetSkills).isEmpty {
            items.append(externalAgentItem(
                itemType: "SKILLS",
                description: "Migrate skills from \(sourceSkills) to \(targetSkills)",
                cwd: cwd,
                details: nil))
        }

        let sourceCommands = sourceRoot + "/commands"
        let commandNames = try missingExternalAgentCommandNames(
            sourceCommands: sourceCommands, targetSkills: targetSkills)
        if !commandNames.isEmpty {
            items.append(externalAgentItem(
                itemType: "COMMANDS",
                description: "Migrate commands from \(sourceCommands) to \(targetSkills)",
                cwd: cwd,
                details: .object(["commands": .array(commandNames
                    .map { .object(["name": .string($0)]) })])))
        }

        let sourceSubagents = sourceRoot + "/agents"
        let targetSubagents = externalAgentTargetAgentsRoot(codexHome: codexHome, cwd: cwd)
        let subagentNames = try missingExternalAgentSubagentNames(
            sourceAgents: sourceSubagents, targetAgents: targetSubagents)
        if !subagentNames.isEmpty {
            items.append(externalAgentItem(
                itemType: "SUBAGENTS",
                description: "Migrate subagents from \(sourceSubagents) to \(targetSubagents)",
                cwd: cwd,
                details: .object(["subagents": .array(subagentNames
                    .map { .object(["name": .string($0)]) })])))
        }

        let sourceAgents = sourceRoot + "/CLAUDE.md"
        let targetAgents = cwd.map { $0 + "/AGENTS.md" } ?? (codexHome + "/AGENTS.md")
        if isNonEmptyTextFile(sourceAgents), isMissingOrEmptyTextFile(targetAgents) {
            items.append(externalAgentItem(
                itemType: "AGENTS_MD",
                description: "Migrate \(sourceAgents) to \(targetAgents)",
                cwd: cwd,
                details: nil))
        }

        let plugins = try migratedExternalAgentPlugins(
            settingsPath: sourceRoot + "/settings.json",
            targetRoot: targetRoot)
        if !plugins.isEmpty {
            let marketplaceCount = plugins.count
            let pluginCount = plugins.reduce(0) { $0 + $1.pluginNames.count }
            items.append(externalAgentItem(
                itemType: "PLUGINS",
                description: "Migrate enabled plugins from \(sourceRoot + "/settings.json")",
                cwd: cwd,
                details: .object([
                    "plugins": .array(plugins.map(pluginGroupJSON)),
                    "marketplaceCount": .int(Int64(marketplaceCount)),
                    "pluginCount": .int(Int64(pluginCount)),
                ])))
        }

        if cwd == nil {
            let sessions = try detectExternalAgentSessions(codexHome: codexHome)
            if !sessions.isEmpty {
                items.append(externalAgentItem(
                    itemType: "SESSIONS",
                    description: "Migrate sessions from \(externalAgentSessionsRoot(codexHome: codexHome))",
                    cwd: nil,
                    details: .object(["sessions": .array(sessions.map(sessionCandidateJSON))])))
            }
        }
    }

    private func importExternalAgentConfig(items: [ExternalAgentMigrationItem]) async throws {
        for item in items {
            let sourceRoot = Self.externalAgentSourceRoot(codexHome: codexHome, cwd: item.cwd)
            let targetRoot = Self.externalAgentTargetRoot(codexHome: codexHome, cwd: item.cwd)
            switch item.itemType {
            case "CONFIG":
                guard let migrated = try Self.migratedExternalAgentConfig(
                    settingsPath: sourceRoot + "/settings.json") else { continue }
                var root = try Self.readUserConfigTOML(path: targetRoot + "/config.toml")
                _ = Self.mergeMissingConfigValues(into: &root, incoming: migrated)
                try? FileManager.default.createDirectory(atPath: targetRoot,
                                                         withIntermediateDirectories: true)
                try Data(TOML.serialize(root).utf8).write(
                    to: URL(fileURLWithPath: targetRoot + "/config.toml"), options: .atomic)
            case "MCP_SERVER_CONFIG":
                guard let migrated = try Self.migratedExternalAgentMcpConfig(
                    codexHome: codexHome, cwd: item.cwd) else { continue }
                if migrated.isEmpty { continue }
                var root = try Self.readUserConfigTOML(path: targetRoot + "/config.toml")
                _ = Self.mergeMissingConfigValues(into: &root, incoming: migrated)
                try? FileManager.default.createDirectory(atPath: targetRoot,
                                                         withIntermediateDirectories: true)
                try Data(TOML.serialize(root).utf8).write(
                    to: URL(fileURLWithPath: targetRoot + "/config.toml"), options: .atomic)
            case "HOOKS":
                try Self.importExternalAgentHooks(sourceRoot: sourceRoot, targetRoot: targetRoot)
            case "SKILLS":
                try Self.copyMissingChildDirectories(
                    source: sourceRoot + "/skills",
                    target: Self.externalAgentTargetSkillsRoot(codexHome: codexHome, cwd: item.cwd))
            case "COMMANDS":
                try Self.importExternalAgentCommands(
                    sourceCommands: sourceRoot + "/commands",
                    targetSkills: Self.externalAgentTargetSkillsRoot(codexHome: codexHome, cwd: item.cwd))
            case "SUBAGENTS":
                try Self.importExternalAgentSubagents(
                    sourceAgents: sourceRoot + "/agents",
                    targetAgents: Self.externalAgentTargetAgentsRoot(codexHome: codexHome, cwd: item.cwd))
            case "AGENTS_MD":
                let target = item.cwd.map { $0 + "/AGENTS.md" } ?? (codexHome + "/AGENTS.md")
                if Self.isMissingOrEmptyTextFile(target), Self.isNonEmptyTextFile(sourceRoot + "/CLAUDE.md") {
                    try? FileManager.default.createDirectory(
                        atPath: (target as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: target) {
                        try FileManager.default.removeItem(atPath: target)
                    }
                    try FileManager.default.copyItem(atPath: sourceRoot + "/CLAUDE.md",
                                                     toPath: target)
                }
            case "SESSIONS":
                try await importExternalAgentSessions(item: item)
            case "PLUGINS":
                try Self.importExternalAgentPlugins(
                    codexHome: codexHome,
                    sourceRoot: sourceRoot,
                    targetRoot: targetRoot,
                    item: item)
            default:
                throw SimpleError("unsupported external agent migration item type \(item.itemType)")
            }
        }
    }

    private static func externalAgentMigrationItems(from params: JSONValue?) throws
        -> [ExternalAgentMigrationItem] {
        guard let values = params?["migrationItems"]?.arrayValue else {
            throw SimpleError("externalAgentConfig/import requires migrationItems")
        }
        return try values.map { value in
            guard let itemType = value["itemType"]?.stringValue else {
                throw SimpleError("externalAgentConfig/import migration items require itemType")
            }
            return ExternalAgentMigrationItem(itemType: itemType,
                                              cwd: value["cwd"]?.stringValue,
                                              details: value["details"])
        }
    }

    private static func externalAgentItem(itemType: String, description: String,
                                          cwd: String?, details: JSONValue?) -> JSONValue {
        .object([
            "itemType": .string(itemType),
            "description": .string(description),
            "cwd": cwd.map(JSONValue.string) ?? .null,
            "details": details ?? .null,
        ])
    }

    private static func externalAgentHome(codexHome: String) -> String {
        URL(fileURLWithPath: codexHome).deletingLastPathComponent()
            .appendingPathComponent(".claude").standardizedFileURL.path
    }

    private static func externalAgentSourceRoot(codexHome: String, cwd: String?) -> String {
        cwd.map { standardizedPath($0 + "/.claude") } ?? externalAgentHome(codexHome: codexHome)
    }

    private static func externalAgentTargetRoot(codexHome: String, cwd: String?) -> String {
        cwd.map { standardizedPath($0 + "/.codex") } ?? standardizedPath(codexHome)
    }

    private static func externalAgentTargetSkillsRoot(codexHome: String, cwd: String?) -> String {
        if let cwd { return standardizedPath(cwd + "/.agents/skills") }
        return URL(fileURLWithPath: codexHome).deletingLastPathComponent()
            .appendingPathComponent(".agents/skills").standardizedFileURL.path
    }

    private static func externalAgentTargetAgentsRoot(codexHome: String, cwd: String?) -> String {
        if let cwd { return standardizedPath(cwd + "/.codex/agents") }
        return standardizedPath(codexHome + "/agents")
    }

    private static func externalAgentMcpSourceRoot(codexHome: String, cwd: String?) -> String {
        if let cwd { return standardizedPath(cwd) }
        return URL(fileURLWithPath: codexHome).deletingLastPathComponent()
            .standardizedFileURL.path
    }

    private static func externalAgentSessionsRoot(codexHome: String) -> String {
        standardizedPath(externalAgentHome(codexHome: codexHome) + "/projects")
    }

    private static func externalAgentSessionLedgerPath(codexHome: String) -> String {
        standardizedPath(codexHome + "/external-agent-session-imports.json")
    }

    private static func pluginCacheRoot(codexHome: String) -> String {
        standardizedPath(codexHome + "/plugins/cache")
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func findRepoRoot(startingAt path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue {
            url.deleteLastPathComponent()
        }
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    private static func migratedExternalAgentConfig(settingsPath: String) throws
        -> [String: ConfigValue]? {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimpleError("external agent settings root must be an object")
        }
        var root: [String: ConfigValue] = [:]
        if let env = object["env"] as? [String: Any] {
            var set: [String: ConfigValue] = [:]
            for (key, value) in env.sorted(by: { $0.key < $1.key }) {
                if value is NSNull { continue }
                if let s = value as? String { set[key] = .string(s) }
                else if let b = value as? Bool { set[key] = .string(b ? "true" : "false") }
                else if let n = value as? NSNumber { set[key] = .string(n.stringValue) }
            }
            if !set.isEmpty {
                root["shell_environment_policy"] = .object([
                    "inherit": .string("core"),
                    "set": .object(set),
                ])
            }
        }
        if let sandbox = object["sandbox"] as? [String: Any],
           let enabled = sandbox["enabled"] as? Bool,
           enabled {
            root["sandbox_mode"] = .string("workspace-write")
        }
        return root
    }

    private static func migratedExternalAgentPlugins(settingsPath: String,
                                                     targetRoot: String) throws
        -> [ExternalAgentPluginGroup] {
        guard let settings = try readJSONObject(path: settingsPath) else { return [] }
        guard let enabledPlugins = settings["enabledPlugins"] as? [String: Any] else {
            return []
        }
        let existingConfig = try readUserConfigTOML(path: targetRoot + "/config.toml")
        var grouped: [String: Set<String>] = [:]
        for key in enabledPlugins.keys.sorted() {
            guard externalAgentPluginEnabled(enabledPlugins[key]) else { continue }
            guard let (pluginName, marketplaceName) = parsePluginKey(key) else { continue }
            if pluginAlreadyEnabled(pluginKey: key, config: existingConfig) { continue }
            grouped[marketplaceName, default: []].insert(pluginName)
        }
        guard !grouped.isEmpty else { return [] }
        let marketplaces = settings["extraKnownMarketplaces"] as? [String: Any] ?? [:]
        return grouped.keys.sorted().map { marketplaceName in
            ExternalAgentPluginGroup(
                marketplaceName: marketplaceName,
                pluginNames: Array(grouped[marketplaceName] ?? []).sorted(),
                marketplaceRoot: externalAgentMarketplaceRoot(
                    marketplaceName: marketplaceName,
                    marketSettings: marketplaces[marketplaceName]))
        }
    }

    private static func externalAgentPluginEnabled(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return false
        }
    }

    private static func parsePluginKey(_ key: String) -> (pluginName: String, marketplaceName: String)? {
        let pieces = key.split(separator: "@", maxSplits: 1).map(String.init)
        guard pieces.count == 2, isSafePluginSegment(pieces[0]), isSafePluginSegment(pieces[1]) else {
            return nil
        }
        return (pieces[0], pieces[1])
    }

    private static func isSafePluginSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              value != ".", value != "..", !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z")
                || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_"
        }
    }

    private static func pluginAlreadyEnabled(pluginKey: String,
                                             config: [String: ConfigValue]) -> Bool {
        guard case .object(let plugins)? = config["plugins"],
              case .object(let plugin)? = plugins[pluginKey],
              case .bool(true)? = plugin["enabled"] else {
            return false
        }
        return true
    }

    private static func externalAgentMarketplaceRoot(marketplaceName: String,
                                                     marketSettings: Any?) -> String? {
        guard let object = marketSettings as? [String: Any] else { return nil }
        if let source = object["source"] as? String {
            if source == "local", let path = object["path"] as? String {
                return standardizedPath(path)
            }
            if source.hasPrefix("/") { return standardizedPath(source) }
        }
        if let path = object["path"] as? String {
            return standardizedPath(path)
        }
        if let local = object["local"] as? String {
            return standardizedPath(local)
        }
        if let root = object["root"] as? String {
            return standardizedPath(root)
        }
        _ = marketplaceName
        return nil
    }

    private static func pluginGroupJSON(_ group: ExternalAgentPluginGroup) -> JSONValue {
        .object([
            "marketplaceName": .string(group.marketplaceName),
            "pluginNames": .array(group.pluginNames.map(JSONValue.string)),
            "marketplaceRoot": group.marketplaceRoot.map(JSONValue.string) ?? .null,
        ])
    }

    private static func externalAgentPluginGroups(from item: ExternalAgentMigrationItem,
                                                  sourceRoot: String,
                                                  targetRoot: String) throws
        -> [ExternalAgentPluginGroup] {
        if let values = item.details?["plugins"]?.arrayValue {
            return try values.map { value in
                guard let marketplaceName = value["marketplaceName"]?.stringValue,
                      isSafePluginSegment(marketplaceName) else {
                    throw SimpleError("PLUGINS migration item requires valid marketplaceName")
                }
                let names = value["pluginNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let safeNames = names.filter(isSafePluginSegment)
                guard safeNames.count == names.count, !safeNames.isEmpty else {
                    throw SimpleError("PLUGINS migration item requires valid pluginNames")
                }
                return ExternalAgentPluginGroup(
                    marketplaceName: marketplaceName,
                    pluginNames: Array(Set(safeNames)).sorted(),
                    marketplaceRoot: value["marketplaceRoot"]?.stringValue.map(standardizedPath))
            }
        }
        return try migratedExternalAgentPlugins(settingsPath: sourceRoot + "/settings.json",
                                                targetRoot: targetRoot)
    }

    private static func importExternalAgentPlugins(codexHome: String,
                                                   sourceRoot: String,
                                                   targetRoot: String,
                                                   item: ExternalAgentMigrationItem) throws {
        let groups = try externalAgentPluginGroups(from: item, sourceRoot: sourceRoot,
                                                   targetRoot: targetRoot)
        guard !groups.isEmpty else { return }
        var root = try readUserConfigTOML(path: targetRoot + "/config.toml")
        for group in groups {
            if let marketplaceRoot = group.marketplaceRoot {
                try ensureMarketplaceConfig(name: group.marketplaceName,
                                            marketplaceRoot: marketplaceRoot,
                                            root: &root)
                let entries = try marketplacePluginEntries(marketplaceRoot: marketplaceRoot)
                for pluginName in group.pluginNames {
                    guard let entry = entries[pluginName] else { continue }
                    if let sourcePath = entry.sourcePath {
                        try installLocalPlugin(codexHome: codexHome,
                                               marketplaceName: group.marketplaceName,
                                               pluginName: pluginName,
                                               sourcePath: sourcePath)
                    }
                    enablePlugin(pluginKey: "\(pluginName)@\(group.marketplaceName)",
                                 root: &root)
                }
            } else {
                for pluginName in group.pluginNames {
                    enablePlugin(pluginKey: "\(pluginName)@\(group.marketplaceName)",
                                 root: &root)
                }
            }
        }
        try? FileManager.default.createDirectory(atPath: targetRoot, withIntermediateDirectories: true)
        try Data(TOML.serialize(root).utf8).write(
            to: URL(fileURLWithPath: targetRoot + "/config.toml"), options: .atomic)
    }

    private static func ensureMarketplaceConfig(name: String,
                                                marketplaceRoot: String,
                                                root: inout [String: ConfigValue]) throws {
        guard FileManager.default.fileExists(atPath: marketplaceManifestPath(marketplaceRoot) ?? "") else {
            throw SimpleError("marketplace \(name) does not contain a supported marketplace.json")
        }
        var marketplaces: [String: ConfigValue]
        if case .object(let existing)? = root["marketplaces"] { marketplaces = existing }
        else { marketplaces = [:] }
        marketplaces[name] = .object([
            "source_type": .string("local"),
            "source": .string(standardizedPath(marketplaceRoot)),
        ])
        root["marketplaces"] = .object(marketplaces)
    }

    private static func enablePlugin(pluginKey: String, root: inout [String: ConfigValue]) {
        var plugins: [String: ConfigValue]
        if case .object(let existing)? = root["plugins"] { plugins = existing }
        else { plugins = [:] }
        var plugin: [String: ConfigValue]
        if case .object(let existing)? = plugins[pluginKey] { plugin = existing }
        else { plugin = [:] }
        plugin["enabled"] = .bool(true)
        plugins[pluginKey] = .object(plugin)
        root["plugins"] = .object(plugins)
    }

    private static func disablePlugin(pluginKey: String, root: inout [String: ConfigValue]) {
        guard case .object(var plugins)? = root["plugins"] else { return }
        plugins.removeValue(forKey: pluginKey)
        root["plugins"] = plugins.isEmpty ? nil : .object(plugins)
    }

    private static func writeUserConfigTOML(_ root: [String: ConfigValue],
                                            codexHome: String) throws {
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        try Data(TOML.serialize(root).utf8).write(
            to: URL(fileURLWithPath: codexHome + "/config.toml"), options: .atomic)
    }

    private static func marketplacePluginEntries(marketplaceRoot: String) throws
        -> [String: MarketplacePluginEntry] {
        guard let manifestPath = marketplaceManifestPath(marketplaceRoot),
              let manifest = try readJSONObject(path: manifestPath) else {
            return [:]
        }
        guard let marketplaceName = manifest["name"] as? String,
              let plugins = manifest["plugins"] as? [Any] else { return [:] }
        _ = marketplaceName
        var entries: [String: MarketplacePluginEntry] = [:]
        for value in plugins {
            guard let object = value as? [String: Any],
                  let name = object["name"] as? String,
                  isSafePluginSegment(name),
                  let source = pluginSourceJSON(object["source"],
                                                marketplaceRoot: marketplaceRoot) else {
                continue
            }
            let sourcePath = source["path"]?.stringValue
            let version = sourcePath.flatMap(pluginManifestVersion)
            entries[name] = MarketplacePluginEntry(name: name, source: source,
                                                   sourcePath: sourcePath, version: version)
        }
        return entries
    }

    private static func marketplaceManifestPath(_ root: String) -> String? {
        for relative in [".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"] {
            let path = standardizedPath(root + "/" + relative)
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func pluginSourceJSON(_ raw: Any?, marketplaceRoot: String) -> JSONValue? {
        if let source = raw as? String {
            guard let path = resolveLocalPluginSource(source, marketplaceRoot: marketplaceRoot) else {
                return nil
            }
            return .object(["type": .string("local"), "path": .string(path)])
        }
        guard let object = raw as? [String: Any] else { return nil }
        let kind = (object["source"] as? String) ?? (object["type"] as? String)
        if kind == "local" {
            guard let rawPath = object["path"] as? String,
                  let path = resolveLocalPluginSource(rawPath, marketplaceRoot: marketplaceRoot) else {
                return nil
            }
            return .object(["type": .string("local"), "path": .string(path)])
        }
        if kind == "git" || object["url"] != nil {
            guard let url = object["url"] as? String, !url.isEmpty else { return nil }
            var out: [String: JSONValue] = ["type": .string("git"), "url": .string(url)]
            if let path = object["path"] as? String { out["path"] = .string(path) }
            if let refName = object["refName"] as? String { out["refName"] = .string(refName) }
            if let sha = object["sha"] as? String { out["sha"] = .string(sha) }
            return .object(out)
        }
        return nil
    }

    private static func resolveLocalPluginSource(_ source: String,
                                                 marketplaceRoot: String) -> String? {
        guard source.hasPrefix("./") else { return nil }
        let relative = String(source.dropFirst(2))
        guard !relative.isEmpty else { return nil }
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return standardizedPath(([marketplaceRoot] + parts).joined(separator: "/"))
    }

    private static func installLocalPlugin(codexHome: String,
                                           marketplaceName: String,
                                           pluginName: String,
                                           sourcePath: String) throws {
        guard let manifestPath = pluginManifestPath(sourcePath),
              let manifest = try readJSONObject(path: manifestPath),
              let manifestName = manifest["name"] as? String,
              manifestName == pluginName else {
            throw SimpleError("plugin \(pluginName) is missing a matching plugin.json")
        }
        let version = pluginManifestVersion(sourcePath) ?? "local"
        guard isSafePluginVersion(version) else {
            throw SimpleError("plugin \(pluginName) has an unsafe version")
        }
        let target = pluginCacheRoot(codexHome: codexHome)
            + "/\(marketplaceName)/\(pluginName)/\(version)"
        try? FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.copyItem(atPath: sourcePath, toPath: target)
    }

    private static func pluginManifestPath(_ pluginRoot: String) -> String? {
        for relative in [".codex-plugin/plugin.json", ".claude-plugin/plugin.json"] {
            let path = standardizedPath(pluginRoot + "/" + relative)
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func pluginManifestVersion(_ pluginRoot: String) -> String? {
        guard let path = pluginManifestPath(pluginRoot),
              let object = try? readJSONObject(path: path),
              let version = (object["version"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return nil
        }
        return version
    }

    private static func isSafePluginVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z")
                || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_"
                || $0 == "." || $0 == "+"
        }
    }

    private static func detectExternalAgentSessions(codexHome: String) throws
        -> [ExternalAgentSessionCandidate] {
        let root = externalAgentSessionsRoot(codexHome: codexHome)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
              isDir.boolValue else { return [] }
        let ledger = try readExternalAgentSessionLedger(codexHome: codexHome)
        let paths = try externalAgentSessionFiles(root: root)
        return try paths.compactMap { path in
            guard let candidate = try parseExternalAgentSession(path: path) else { return nil }
            if ledger.imported[candidate.path]?.version == candidate.version { return nil }
            return candidate
        }
    }

    private static func externalAgentSessionFiles(root: String) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [String] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" { files.append(standardizedPath(url.path)) }
        }
        return files.sorted()
    }

    private static func parseExternalAgentSession(path rawPath: String) throws
        -> ExternalAgentSessionCandidate? {
        let path = standardizedPath(rawPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var cwd: String?
        var title: String?
        var messages: [(role: String, text: String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }
            if cwd == nil, let recordCwd = object["cwd"] as? String {
                cwd = standardizedPath(recordCwd)
            }
            if type == "custom-title" {
                if let customTitle = (object["customTitle"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !customTitle.isEmpty {
                    title = customTitle
                }
                continue
            }
            guard type == "user" || type == "assistant",
                  let content = externalAgentSessionMessageText(object),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            messages.append((role: type, text: content))
        }
        guard let cwd, FileManager.default.fileExists(atPath: cwd),
              !messages.isEmpty,
              messages.contains(where: { $0.role == "user" }) else {
            return nil
        }
        let resolvedTitle = title ?? messages.first(where: { $0.role == "user" }).map {
            externalAgentSessionTitle(from: $0.text)
        }
        return ExternalAgentSessionCandidate(path: path, cwd: cwd, title: resolvedTitle,
                                             version: externalAgentSessionVersion(path: path),
                                             messages: messages)
    }

    private static func externalAgentSessionMessageText(_ object: [String: Any]) -> String? {
        if let message = object["message"] as? [String: Any],
           let text = externalAgentSessionContentText(message["content"]) {
            return text
        }
        return externalAgentSessionContentText(object["content"])
    }

    private static func externalAgentSessionContentText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let parts = value as? [Any] {
            let texts = parts.compactMap { part -> String? in
                if let text = part as? String { return text }
                if let object = part as? [String: Any] {
                    return object["text"] as? String
                        ?? object["content"] as? String
                }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    private static func externalAgentSessionTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "Imported external session"
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed.isEmpty ? "Imported external session" : trimmed }
        return String(trimmed.prefix(77)) + "..."
    }

    private static func sessionCandidateJSON(_ candidate: ExternalAgentSessionCandidate) -> JSONValue {
        .object([
            "path": .string(candidate.path),
            "cwd": .string(candidate.cwd),
            "title": candidate.title.map(JSONValue.string) ?? .null,
            "version": .string(candidate.version),
        ])
    }

    private static func externalAgentSessionVersion(path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "0-0"
        }
        let modified = milliseconds(attrs[.modificationDate] as? Date)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return "\(modified)-\(size)"
    }

    private static func readExternalAgentSessionLedger(codexHome: String) throws
        -> ExternalAgentSessionLedger {
        let path = externalAgentSessionLedgerPath(codexHome: codexHome)
        guard FileManager.default.fileExists(atPath: path) else {
            return ExternalAgentSessionLedger()
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ExternalAgentSessionLedger.self, from: data)
    }

    private static func writeExternalAgentSessionLedger(_ ledger: ExternalAgentSessionLedger,
                                                        codexHome: String) throws {
        let path = externalAgentSessionLedgerPath(codexHome: codexHome)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ledger).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func externalAgentSessionCandidates(from item: ExternalAgentMigrationItem,
                                                       codexHome: String) throws
        -> [ExternalAgentSessionCandidate] {
        let projectsRoot = externalAgentSessionsRoot(codexHome: codexHome)
        guard let sessions = item.details?["sessions"]?.arrayValue else {
            return try detectExternalAgentSessions(codexHome: codexHome)
        }
        return try sessions.compactMap { value in
            guard let pathValue = value["path"]?.stringValue else {
                throw SimpleError("SESSIONS migration item requires details.sessions[].path")
            }
            let path = standardizedPath(pathValue)
            guard pathIsDescendantOrEqual(path, of: projectsRoot) else {
                throw SimpleError("external session path is outside \(projectsRoot)")
            }
            guard let candidate = try parseExternalAgentSession(path: path) else { return nil }
            if let cwdValue = value["cwd"]?.stringValue,
               standardizedPath(cwdValue) != candidate.cwd {
                throw SimpleError("external session cwd does not match source record")
            }
            return candidate
        }
    }

    private static func pathIsDescendantOrEqual(_ path: String, of root: String) -> Bool {
        let path = standardizedPath(path)
        let root = standardizedPath(root)
        return path == root || path.hasPrefix(root + "/")
    }

    private func importExternalAgentSessions(item: ExternalAgentMigrationItem) async throws {
        var ledger = try Self.readExternalAgentSessionLedger(codexHome: codexHome)
        let candidates = try Self.externalAgentSessionCandidates(from: item, codexHome: codexHome)
        for candidate in candidates {
            if ledger.imported[candidate.path]?.version == candidate.version { continue }
            let threadId = ThreadId.generate()
            let turnId = TurnId.generate()
            let cfg = SessionConfig(threadId: threadId, cwd: candidate.cwd)
            _ = try await store.create(cfg)
            try await store.record(threadId, .turnBoundary(turnId: turnId, status: .inProgress))
            for message in candidate.messages {
                if message.role == "user" {
                    try await store.record(threadId, .userInput(
                        turnId: turnId,
                        input: [TurnInput(text: message.text)]))
                } else {
                    try await store.record(threadId, .item(
                        turnId: turnId,
                        item: .agentMessage(id: ItemId.generate("external"), text: message.text)))
                }
            }
            try await store.record(threadId, .item(
                turnId: turnId,
                item: .agentMessage(id: ItemId.generate("external"),
                                    text: "<EXTERNAL SESSION IMPORTED>")))
            try await store.record(threadId, .turnBoundary(turnId: turnId, status: .completed))
            try await store.durabilityBarrier(threadId)
            if let title = candidate.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await store.setName(threadId, title)
            }
            ledger.imported[candidate.path] = .init(threadId: threadId.raw, version: candidate.version)
            try Self.writeExternalAgentSessionLedger(ledger, codexHome: codexHome)
        }
    }

    private static func migratedExternalAgentMcpConfig(codexHome: String,
                                                       cwd: String?) throws
        -> [String: ConfigValue]? {
        let sourceRoot = externalAgentMcpSourceRoot(codexHome: codexHome, cwd: cwd)
        let sourceSettings = externalAgentSourceRoot(codexHome: codexHome, cwd: cwd) + "/settings.json"
        let settings = try readJSONObject(path: sourceSettings) ?? [:]
        let enabled = stringSet(from: settings["enabledMcpjsonServers"])
        let disabled = stringSet(from: settings["disabledMcpjsonServers"])
        var servers: [String: [String: Any]] = [:]
        for file in [
            sourceRoot + "/.mcp.json",
            sourceRoot + "/.claude.json",
            externalAgentSourceRoot(codexHome: codexHome, cwd: cwd) + "/.mcp.json",
        ] {
            guard let object = try readJSONObject(path: file) else { continue }
            appendExternalMcpServers(from: object, into: &servers)
            if file.hasSuffix(".claude.json"),
               let projects = object["projects"] as? [String: Any] {
                for (project, value) in projects where standardizedPath(project) == sourceRoot {
                    if let projectObject = value as? [String: Any] {
                        appendExternalMcpServers(from: projectObject, into: &servers)
                    }
                }
            }
        }
        var out: [String: ConfigValue] = [:]
        for name in servers.keys.sorted() {
            guard enabled.isEmpty || enabled.contains(name),
                  !disabled.contains(name),
                  let table = externalMcpServerConfig(name: name, object: servers[name] ?? [:]) else {
                continue
            }
            out[name] = .object(table)
        }
        if out.isEmpty { return nil }
        return ["mcp_servers": .object(out)]
    }

    private static func appendExternalMcpServers(from object: [String: Any],
                                                 into servers: inout [String: [String: Any]]) {
        guard let rawServers = object["mcpServers"] as? [String: Any] else { return }
        for (name, value) in rawServers {
            if let server = value as? [String: Any] {
                servers[name] = server
            }
        }
    }

    private static func externalMcpServerConfig(name: String,
                                                object: [String: Any]) -> [String: ConfigValue]? {
        if (object["enabled"] as? Bool) == false || (object["disabled"] as? Bool) == true {
            return nil
        }
        let transport = object["type"] as? String
        var table: [String: ConfigValue] = [:]
        if let command = jsonScalarString(object["command"] as Any) {
            guard transport == nil || transport == "stdio",
                  !command.contains("${") else { return nil }
            table["command"] = .string(command)
            if let args = object["args"] {
                let argStrings = jsonStringArray(args)
                guard !argStrings.contains(where: { $0.contains("${") }) else { return nil }
                if !argStrings.isEmpty {
                    table["args"] = .array(argStrings.map { .string($0) })
                }
            }
            if let env = object["env"] as? [String: Any] {
                guard appendExternalMcpEnv(env, into: &table) else { return nil }
            }
        } else if let url = jsonScalarString(object["url"] as Any) {
            guard transport == nil || transport == "http" || transport == "streamable_http",
                  !url.contains("${") else { return nil }
            table["url"] = .string(url)
            if let headers = object["headers"] as? [String: Any] {
                guard appendExternalMcpHeaders(headers, into: &table) else { return nil }
            }
        } else {
            return nil
        }
        return table.isEmpty ? nil : table
    }

    private static func appendExternalMcpEnv(_ env: [String: Any],
                                             into table: inout [String: ConfigValue]) -> Bool {
        var envVars: [ConfigValue] = []
        var staticEnv: [String: ConfigValue] = [:]
        for key in env.keys.sorted() {
            let value = jsonScalarString(env[key] as Any)
            guard let value else { continue }
            if parseEnvPlaceholder(value) == key {
                envVars.append(.string(key))
            } else if value.contains("${") {
                return false
            } else {
                staticEnv[key] = .string(value)
            }
        }
        if !envVars.isEmpty { table["env_vars"] = .array(envVars) }
        if !staticEnv.isEmpty { table["env"] = .object(staticEnv) }
        return true
    }

    private static func appendExternalMcpHeaders(_ headers: [String: Any],
                                                 into table: inout [String: ConfigValue]) -> Bool {
        var staticHeaders: [String: ConfigValue] = [:]
        var envHeaders: [String: ConfigValue] = [:]
        for key in headers.keys.sorted() {
            guard let value = jsonScalarString(headers[key] as Any) else { continue }
            if key.lowercased() == "authorization",
               value.hasPrefix("Bearer "),
               let env = parseEnvPlaceholder(String(value.dropFirst("Bearer ".count))) {
                table["bearer_token_env_var"] = .string(env)
                continue
            }
            if let env = parseEnvPlaceholder(value) {
                envHeaders[key] = .string(env)
            } else if value.contains("${") {
                return false
            } else {
                staticHeaders[key] = .string(value)
            }
        }
        if !staticHeaders.isEmpty { table["http_headers"] = .object(staticHeaders) }
        if !envHeaders.isEmpty { table["env_http_headers"] = .object(envHeaders) }
        return true
    }

    private static func migratedMcpServerNames(_ root: [String: ConfigValue]) -> [String] {
        guard case .object(let servers)? = root["mcp_servers"] else { return [] }
        return servers.keys.sorted()
    }

    private static let externalHookEventMap: [String: String] = [
        "PreToolUse": "pre-tool-use",
        "PermissionRequest": "permission-request",
        "PostToolUse": "post-tool-use",
        "PreCompact": "pre-compact",
        "PostCompact": "post-compact",
        "SessionStart": "session-start",
        "UserPromptSubmit": "user-prompt-submit",
        "Stop": "stop",
    ]

    private static let externalHookEventsWithMatchers: Set<String> = [
        "PreToolUse", "PermissionRequest", "PostToolUse",
        "PreCompact", "PostCompact", "SessionStart",
    ]

    private static func migratedExternalAgentHooks(sourceRoot: String,
                                                   targetRoot: String) throws -> [JSONValue] {
        var disableAll: Bool?
        var settingsObjects: [[String: Any]] = []
        for name in ["settings.json", "settings.local.json"] {
            guard let object = try readJSONObject(path: sourceRoot + "/" + name) else { continue }
            if let disabled = object["disableAllHooks"] as? Bool {
                disableAll = disabled
            }
            settingsObjects.append(object)
        }
        guard disableAll != true else { return [] }
        var hooks: [JSONValue] = []
        for settings in settingsObjects {
            guard let hooksConfig = settings["hooks"] as? [String: Any] else { continue }
            for eventName in externalHookEventMap.keys.sorted() {
                guard let groups = hooksConfig[eventName] as? [Any] else { continue }
                for groupValue in groups {
                    guard let group = groupValue as? [String: Any],
                          !group.keys.contains(where: { !["matcher", "hooks"].contains($0) }),
                          group["if"] == nil,
                          let hookValues = group["hooks"] as? [Any] else {
                        continue
                    }
                    for hookValue in hookValues {
                        guard let hook = hookValue as? [String: Any],
                              (hook["type"] as? String ?? "command") == "command",
                              !hook.keys.contains(where: {
                                  !["type", "command", "timeout", "timeoutSec", "statusMessage", "async"].contains($0)
                              }),
                              (hook["async"] as? Bool) != true,
                              let command = (hook["command"] as? String)?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                              !command.isEmpty else {
                            continue
                        }
                        var out: [String: JSONValue] = [
                            "event": .string(externalHookEventMap[eventName] ?? eventName),
                            "command": .string(rewriteExternalHookCommand(command,
                                                                          targetRoot: targetRoot)),
                        ]
                        if externalHookEventsWithMatchers.contains(eventName),
                           let matcher = hookString(group["matcher"]) {
                            out["matcher"] = .string(matcher)
                        }
                        if let timeout = hookUInt(hook["timeout"] ?? hook["timeoutSec"]) {
                            out["timeout"] = .int(Int64(timeout))
                        }
                        hooks.append(.object(out))
                    }
                }
            }
        }
        return hooks
    }

    private static func importExternalAgentHooks(sourceRoot: String, targetRoot: String) throws {
        let targetHooks = targetRoot + "/hooks.json"
        let hooks = try migratedExternalAgentHooks(sourceRoot: sourceRoot, targetRoot: targetRoot)
        guard !hooks.isEmpty, isMissingOrEmptyTextFile(targetHooks) else { return }
        try? FileManager.default.createDirectory(atPath: targetRoot, withIntermediateDirectories: true)
        try copyDirectorySkipExisting(source: sourceRoot + "/hooks", target: targetRoot + "/hooks")
        let payload = JSONValue.object(["hooks": .array(hooks)])
        let data = try JSONEncoder().encode(payload)
        try data.write(to: URL(fileURLWithPath: targetHooks), options: .atomic)
    }

    private static func rewriteExternalHookCommand(_ command: String, targetRoot: String) -> String {
        command.replacingOccurrences(of: ".claude/hooks/",
                                     with: targetRoot + "/hooks/")
    }

    private static func missingExternalAgentSubagentNames(sourceAgents: String,
                                                         targetAgents: String) throws -> [String] {
        try externalAgentMarkdownFiles(sourceAgents, recursive: false).compactMap { file in
            let document = try parseExternalAgentDocument(path: file)
            guard !document.hasFrontmatterError,
                  !document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = document.frontmatter["name"],
                  let description = document.frontmatter["description"],
                  !name.isEmpty, !description.isEmpty else { return nil }
            let target = targetAgents + "/" + ((file as NSString).deletingPathExtension as NSString).lastPathComponent + ".toml"
            return FileManager.default.fileExists(atPath: target) ? nil : name
        }
    }

    private static func importExternalAgentSubagents(sourceAgents: String,
                                                    targetAgents: String) throws {
        let files = try externalAgentMarkdownFiles(sourceAgents, recursive: false)
        guard !files.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: targetAgents, withIntermediateDirectories: true)
        for file in files {
            let stem = ((file as NSString).deletingPathExtension as NSString).lastPathComponent
            guard stem != "README" else { continue }
            let target = targetAgents + "/" + stem + ".toml"
            guard !FileManager.default.fileExists(atPath: target) else { continue }
            let document = try parseExternalAgentDocument(path: file)
            guard !document.hasFrontmatterError,
                  !document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = document.frontmatter["name"],
                  let description = document.frontmatter["description"],
                  !name.isEmpty, !description.isEmpty else { continue }
            var out: [String: ConfigValue] = [
                "name": .string(name),
                "description": .string(rewriteExternalAgentTerms(description)),
                "developer_instructions": .string(rewriteExternalAgentTerms(
                    document.body.trimmingCharacters(in: .whitespacesAndNewlines))),
            ]
            if let effort = document.frontmatter["effort"].flatMap(mapExternalAgentEffort) {
                out["model_reasoning_effort"] = .string(effort)
            }
            if let sandbox = document.frontmatter["permissionMode"].flatMap(mapExternalAgentPermissionMode) {
                out["sandbox_mode"] = .string(sandbox)
            }
            try Data(TOML.serialize(out).utf8).write(to: URL(fileURLWithPath: target), options: .atomic)
        }
    }

    private static func missingExternalAgentCommandNames(sourceCommands: String,
                                                        targetSkills: String) throws -> [String] {
        try supportedExternalAgentCommands(sourceCommands: sourceCommands)
            .filter { !FileManager.default.fileExists(atPath: targetSkills + "/" + $0.name) }
            .map(\.name)
    }

    private static func importExternalAgentCommands(sourceCommands: String,
                                                   targetSkills: String) throws {
        let commands = try supportedExternalAgentCommands(sourceCommands: sourceCommands)
        guard !commands.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: targetSkills, withIntermediateDirectories: true)
        for command in commands {
            let targetDir = targetSkills + "/" + command.name
            guard !FileManager.default.fileExists(atPath: targetDir) else { continue }
            try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            let body = rewriteExternalAgentTerms(
                command.document.body.trimmingCharacters(in: .whitespacesAndNewlines))
            let template = body.isEmpty ? "No command template body was found." : body
            let sourceName = command.sourceName
            let content = """
            ---
            name: \(yamlQuoted(command.name))
            description: \(yamlQuoted(rewriteExternalAgentTerms(command.description)))
            ---

            # \(command.name)

            Use this skill when the user asks to run the migrated source command `\(sourceName)`.

            ## Command Template

            \(template)
            """
            try (content + "\n").write(toFile: targetDir + "/SKILL.md",
                                       atomically: true, encoding: .utf8)
        }
    }

    private static func supportedExternalAgentCommands(sourceCommands: String) throws
        -> [(path: String, sourceName: String, name: String, description: String, document: ParsedExternalAgentDocument)] {
        let files = try externalAgentMarkdownFiles(sourceCommands, recursive: true)
        var byName: [String: [(String, String, String, ParsedExternalAgentDocument)]] = [:]
        for file in files {
            let stem = ((file as NSString).deletingPathExtension as NSString).lastPathComponent
            guard stem != "README" else { continue }
            let document = try parseExternalAgentDocument(path: file)
            guard let description = document.frontmatter["description"],
                  !description.isEmpty,
                  !hasUnsupportedExternalCommandTemplate(document.body) else { continue }
            let sourceName = externalCommandSourceName(sourceCommands: sourceCommands, file: file)
            let name = slugify("source-command-\(sourceName)")
            guard name.count <= 64, description.count <= 1024 else { continue }
            byName[name, default: []].append((file, sourceName, description, document))
        }
        return byName.keys.sorted().compactMap { name in
            guard let entries = byName[name], entries.count == 1, let entry = entries.first else {
                return nil
            }
            return (path: entry.0, sourceName: entry.1, name: name,
                    description: entry.2, document: entry.3)
        }
    }

    private static func externalAgentMarkdownFiles(_ dir: String, recursive: Bool) throws -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue else { return [] }
        var files: [String] = []
        func walk(_ path: String) throws {
            for name in (try FileManager.default.contentsOfDirectory(atPath: path)).sorted() {
                let child = path + "/" + name
                var childIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child, isDirectory: &childIsDir) else {
                    continue
                }
                if childIsDir.boolValue {
                    if recursive { try walk(child) }
                } else if (child as NSString).pathExtension == "md" {
                    files.append(child)
                }
            }
        }
        try walk(dir)
        return files.sorted()
    }

    private static func parseExternalAgentDocument(path: String) throws -> ParsedExternalAgentDocument {
        try parseExternalAgentDocument(content: String(contentsOfFile: path, encoding: .utf8))
    }

    private static func parseExternalAgentDocument(content: String) -> ParsedExternalAgentDocument {
        let newline: String
        let rest: String
        if content.hasPrefix("---\r\n") {
            newline = "\r\n"
            rest = String(content.dropFirst(5))
        } else if content.hasPrefix("---\n") {
            newline = "\n"
            rest = String(content.dropFirst(4))
        } else {
            return ParsedExternalAgentDocument(frontmatter: [:], body: content,
                                               hasFrontmatterError: false)
        }
        guard let endRange = rest.range(of: "\(newline)---\(newline)")
                ?? rest.range(of: "\(newline)---") else {
            return ParsedExternalAgentDocument(frontmatter: [:], body: content,
                                               hasFrontmatterError: false)
        }
        let raw = String(rest[..<endRange.lowerBound])
        let body = String(rest[endRange.upperBound...])
        var values: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let colon = text.firstIndex(of: ":") else {
                return ParsedExternalAgentDocument(frontmatter: [:], body: body,
                                                   hasFrontmatterError: true)
            }
            let key = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = text[text.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            if !key.isEmpty {
                values[key] = value
            }
        }
        return ParsedExternalAgentDocument(frontmatter: values, body: body,
                                           hasFrontmatterError: false)
    }

    private static func externalCommandSourceName(sourceCommands: String, file: String) -> String {
        var relative = file
        if relative.hasPrefix(sourceCommands + "/") {
            relative = String(relative.dropFirst(sourceCommands.count + 1))
        }
        relative = (relative as NSString).deletingPathExtension
        return relative.split(separator: "/").joined(separator: "-")
    }

    private static func hasUnsupportedExternalCommandTemplate(_ template: String) -> Bool {
        template.contains("$ARGUMENTS")
            || template.range(of: #"\$[0-9]"#, options: .regularExpression) != nil
            || (template.contains("{{") && template.contains("}}"))
            || template.contains("!`")
            || template.contains("! `")
            || template.split(whereSeparator: \.isWhitespace)
                .contains { token in
                    token.hasPrefix("@") && token.count > 1
                }
    }

    private static func mapExternalAgentEffort(_ effort: String) -> String? {
        let mapped = effort == "max" ? "xhigh" : effort
        return ["none", "minimal", "low", "medium", "high", "xhigh"].contains(mapped) ? mapped : nil
    }

    private static func mapExternalAgentPermissionMode(_ permissionMode: String) -> String? {
        switch permissionMode {
        case "acceptEdits": return "workspace-write"
        case "readOnly": return "read-only"
        default: return nil
        }
    }

    private static func rewriteExternalAgentTerms(_ content: String) -> String {
        var out = replaceCaseInsensitiveToken(content, "claude.md", with: "AGENTS.md")
        for term in ["claude code", "claude-code", "claude_code", "claudecode", "claude"] {
            out = replaceCaseInsensitiveToken(out, term, with: "Codex")
        }
        return out
    }

    private static func replaceCaseInsensitiveToken(_ input: String,
                                                    _ needle: String,
                                                    with replacement: String) -> String {
        let pattern = "(?i)(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: needle) + "(?![A-Za-z0-9_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    private static func slugify(_ value: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(UnicodeScalar(String(scalar).lowercased())!)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "migrated" : trimmed
    }

    private static func yamlQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readJSONObject(path: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimpleError("JSON root at \(path) must be an object")
        }
        return object
    }

    private static func stringSet(from value: Any?) -> Set<String> {
        Set(jsonStringArray(value as Any))
    }

    private static func jsonStringArray(_ value: Any) -> [String] {
        if let values = value as? [Any] {
            return values.compactMap { jsonScalarString($0) }
        }
        return jsonScalarString(value).map { [$0] } ?? []
    }

    private static func jsonScalarString(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func parseEnvPlaceholder(_ value: String) -> String? {
        guard value.hasPrefix("${"), value.hasSuffix("}") else { return nil }
        let inner = value.dropFirst(2).dropLast()
        let name = inner.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String(inner)
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else { return nil }
        guard name.unicodeScalars.dropFirst().allSatisfy({
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }) else { return nil }
        return name
    }

    private static func hookString(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hookUInt(_ value: Any?) -> UInt64? {
        switch value {
        case let n as NSNumber where !(value is Bool):
            return n.uint64Value
        case let s as String:
            return UInt64(s)
        default:
            return nil
        }
    }

    private static func configMergeWouldChange(existingPath: String,
                                               incoming: [String: ConfigValue]) throws -> Bool {
        guard FileManager.default.fileExists(atPath: existingPath) else { return true }
        var existing = try readUserConfigTOML(path: existingPath)
        return mergeMissingConfigValues(into: &existing, incoming: incoming)
    }

    @discardableResult
    private static func mergeMissingConfigValues(into existing: inout [String: ConfigValue],
                                                 incoming: [String: ConfigValue]) -> Bool {
        var changed = false
        for (key, value) in incoming {
            if existing[key] == nil {
                existing[key] = value
                changed = true
            } else if case .object(var current)? = existing[key],
                      case .object(let overlay) = value {
                let childChanged = mergeMissingConfigValues(into: &current, incoming: overlay)
                if childChanged {
                    existing[key] = .object(current)
                    changed = true
                }
            }
        }
        return changed
    }

    private static func isNonEmptyTextFile(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isMissingOrEmptyTextFile(_ path: String) -> Bool {
        !FileManager.default.fileExists(atPath: path) || isEmptyTextFile(path)
    }

    private static func isEmptyTextFile(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func missingChildDirectoryNames(source: String, target: String) throws -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: source) else {
            return []
        }
        var names: [String] = []
        for name in entries.sorted() {
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let sourcePath = source + "/" + name
            guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if !FileManager.default.fileExists(atPath: target + "/" + name) {
                names.append(name)
            }
        }
        return names
    }

    private static func copyMissingChildDirectories(source: String, target: String) throws {
        let missing = try missingChildDirectoryNames(source: source, target: target)
        guard !missing.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        for name in missing {
            try FileManager.default.copyItem(atPath: source + "/" + name,
                                             toPath: target + "/" + name)
        }
    }

    private static func copyDirectorySkipExisting(source: String, target: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir),
              isDir.boolValue else { return }
        try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: source) {
            let sourcePath = source + "/" + name
            let targetPath = target + "/" + name
            var childIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &childIsDir) else {
                continue
            }
            if childIsDir.boolValue {
                try copyDirectorySkipExisting(source: sourcePath, target: targetPath)
            } else if !FileManager.default.fileExists(atPath: targetPath) {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: targetPath)
            }
        }
    }

    private func handleFilesystemRequest(id: RequestId, method: String,
                                         params: JSONValue?,
                                         conn: any ClientConnection) async -> Bool {
        switch method {
        case "fs/readFile":
            guard let path = absolutePathParam(params, "path") else {
                await conn.send(WireError.invalidRequest(id: id, "fs/readFile requires absolute path"))
                return true
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                await reply(conn, id, .object(["dataBase64": .string(data.base64EncodedString())]))
            } catch {
                await conn.send(WireError.internalError(id: id, error.localizedDescription))
            }
            return true

        case "fs/writeFile":
            guard let path = absolutePathParam(params, "path") else {
                await conn.send(WireError.invalidRequest(id: id, "fs/writeFile requires absolute path"))
                return true
            }
            guard let encoded = params?["dataBase64"]?.stringValue,
                  let data = Data(base64Encoded: encoded) else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fs/writeFile requires valid base64 dataBase64"))
                return true
            }
            do {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                await reply(conn, id, EmptyResponse())
            } catch {
                await conn.send(WireError.internalError(id: id, error.localizedDescription))
            }
            return true

        case "fs/createDirectory":
            guard let path = absolutePathParam(params, "path") else {
                await conn.send(WireError.invalidRequest(id: id, "fs/createDirectory requires absolute path"))
                return true
            }
            let recursive = params?["recursive"]?.boolValue ?? true
            do {
                try FileManager.default.createDirectory(
                    atPath: path, withIntermediateDirectories: recursive)
                await reply(conn, id, EmptyResponse())
            } catch {
                await conn.send(WireError.internalError(id: id, error.localizedDescription))
            }
            return true

        case "fs/getMetadata":
            guard let path = absolutePathParam(params, "path") else {
                await conn.send(WireError.invalidRequest(id: id, "fs/getMetadata requires absolute path"))
                return true
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                let symlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                let isFile = exists && !isDir.boolValue
                await reply(conn, id, .object([
                    "isDirectory": .bool(isDir.boolValue),
                    "isFile": .bool(isFile),
                    "isSymlink": .bool(symlink),
                    "createdAtMs": .int(Self.milliseconds(attrs[.creationDate] as? Date)),
                    "modifiedAtMs": .int(Self.milliseconds(attrs[.modificationDate] as? Date)),
                ]))
            } catch {
                await conn.send(WireError.internalError(id: id, error.localizedDescription))
            }
            return true

        case "fs/readDirectory":
            guard let path = absolutePathParam(params, "path") else {
                await conn.send(WireError.invalidRequest(id: id, "fs/readDirectory requires absolute path"))
                return true
            }
            do {
                let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
                let entries = children.map { child -> JSONValue in
                    let childPath = URL(fileURLWithPath: path).appendingPathComponent(child).path
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: childPath, isDirectory: &isDir)
                    return .object([
                        "fileName": .string(child),
                        "isDirectory": .bool(exists && isDir.boolValue),
                        "isFile": .bool(exists && !isDir.boolValue),
                    ])
                }
                await reply(conn, id, .object(["entries": .array(entries)]))
            } catch {
                await conn.send(WireError.internalError(id: id, error.localizedDescription))
            }
            return true

        case "fs/copy":
            guard let source = absolutePathParam(params, "sourcePath"),
                  let destination = absolutePathParam(params, "destinationPath") else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fs/copy requires absolute sourcePath and destinationPath"))
                return true
            }
            do {
                try FileManager.default.copyItem(atPath: source, toPath: destination)
                await reply(conn, id, EmptyResponse())
            } catch {
                await conn.send(WireError.internalError(id: id, error.localizedDescription))
            }
            return true

        case "fs/remove":
            guard let path = absolutePathParam(params, "path") else {
                await conn.send(WireError.invalidRequest(id: id, "fs/remove requires absolute path"))
                return true
            }
            let force = params?["force"]?.boolValue ?? true
            if !FileManager.default.fileExists(atPath: path) {
                if force {
                    await reply(conn, id, EmptyResponse())
                } else {
                    await conn.send(WireError.internalError(id: id, "No such file or directory"))
                }
                return true
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                await reply(conn, id, EmptyResponse())
            } catch {
                await conn.send(WireError.internalError(id: id, error.localizedDescription))
            }
            return true

        case "fs/watch":
            guard let path = absolutePathParam(params, "path"),
                  let watchId = params?["watchId"]?.stringValue,
                  !watchId.isEmpty else {
                await conn.send(WireError.invalidRequest(
                    id: id, "fs/watch requires absolute path and watchId"))
                return true
            }
            do {
                let response = try await fileWatchManager.watch(
                    conn: conn, watchId: watchId, path: path)
                await reply(conn, id, response)
            } catch {
                await conn.send(WireError.invalidRequest(id: id, error.localizedDescription))
            }
            return true

        case "fs/unwatch":
            guard let watchId = params?["watchId"]?.stringValue, !watchId.isEmpty else {
                await conn.send(WireError.invalidRequest(id: id, "fs/unwatch requires watchId"))
                return true
            }
            await fileWatchManager.unwatch(conn: conn, watchId: watchId)
            await reply(conn, id, EmptyResponse())
            return true

        default:
            return false
        }
    }

    private func absolutePathParam(_ params: JSONValue?, _ key: String) -> String? {
        guard let value = params?[key]?.stringValue,
              value.hasPrefix("/") else { return nil }
        return value
    }

    private static func milliseconds(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func handleCommandExecRequest(id: RequestId, method: String,
                                          params: JSONValue?,
                                          conn: any ClientConnection) async -> Bool {
        switch method {
        case "command/exec/write":
            await handleCommandExecWrite(id: id, params: params, conn: conn)
            return true
        case "command/exec/terminate":
            await handleCommandExecTerminate(id: id, params: params, conn: conn)
            return true
        case "command/exec/resize":
            await handleCommandExecResize(id: id, params: params, conn: conn)
            return true
        case "command/exec":
            break
        default:
            return false
        }
        guard let params, let commandValues = params["command"]?.arrayValue else {
            await conn.send(WireError.invalidRequest(id: id, "missing command"))
            return true
        }
        let command = commandValues.compactMap(\.stringValue)
        guard command.count == commandValues.count else {
            await conn.send(WireError.invalidRequest(id: id, "command must be an array of strings"))
            return true
        }
        guard !command.isEmpty else {
            await conn.send(WireError.invalidRequest(id: id, "command must not be empty"))
            return true
        }
        if params["permissionProfile"] != nil && params["sandboxPolicy"] != nil {
            await conn.send(WireError.invalidRequest(
                id: id, "`permissionProfile` cannot be combined with `sandboxPolicy`"))
            return true
        }
        if params["size"] != nil && params["tty"]?.boolValue != true {
            await conn.send(WireError.invalidRequest(id: id, "command/exec size requires tty: true"))
            return true
        }
        if params["disableOutputCap"]?.boolValue == true && params["outputBytesCap"] != nil {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec cannot set both outputBytesCap and disableOutputCap"))
            return true
        }
        if params["disableTimeout"]?.boolValue == true && params["timeoutMs"] != nil {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec cannot set both timeoutMs and disableTimeout"))
            return true
        }
        let tty = params["tty"]?.boolValue == true
        if tty {
            guard params["processId"]?.stringValue?.isEmpty == false else {
                await conn.send(WireError.invalidRequest(
                    id: id, "command/exec tty or streaming requires a client-supplied processId"))
                return true
            }
        }

        let cwd = params["cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath
        let timeoutMs = params["disableTimeout"]?.boolValue == true
            ? nil
            : Int(params["timeoutMs"]?.intValue ?? 120_000)
        if let timeoutMs, timeoutMs < 0 {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec timeoutMs must be non-negative, got \(timeoutMs)"))
            return true
        }
        let outputCap: Int? = params["disableOutputCap"]?.boolValue == true
            ? nil
            : Int(params["outputBytesCap"]?.intValue ?? 1_048_576)
        let env = commandEnvironment(overrides: params["env"])

        if let processId = params["processId"]?.stringValue, !processId.isEmpty {
            await startCommandExecSession(id: id, processId: processId,
                                          command: command, cwd: cwd,
                                          environment: env,
                                          timeoutMs: timeoutMs,
                                          outputBytesCap: outputCap,
                                          streamOutput: params["streamStdoutStderr"]?.boolValue == true,
                                          streamStdin: params["streamStdin"]?.boolValue == true,
                                          tty: tty,
                                          size: params["size"],
                                          conn: conn)
            return true
        }

        do {
            let result = try Self.runBufferedCommand(command, cwd: cwd,
                                                     environment: env,
                                                     timeoutMs: timeoutMs,
                                                     outputBytesCap: outputCap)
            await reply(conn, id, .object([
                "exitCode": .int(Int64(result.exitCode)),
                "stdout": .string(result.stdout),
                "stderr": .string(result.stderr),
            ]))
        } catch {
            await conn.send(WireError.internalError(id: id, error.localizedDescription))
        }
        return true
    }

    private actor CommandExecOutputBuffer {
        private var stdout = Data()
        private var stderr = Data()
        private let cap: Int?
        private var stdoutCapReached = false
        private var stderrCapReached = false

        init(cap: Int?) {
            self.cap = cap
        }

        func append(_ data: Data, stream: String) -> Bool {
            guard !data.isEmpty else { return false }
            guard let cap else {
                if stream == "stdout" { stdout.append(data) } else { stderr.append(data) }
                return false
            }
            if stream == "stdout" {
                let room = max(0, cap - stdout.count)
                if room > 0 { stdout.append(data.prefix(room)) }
                if data.count > room { stdoutCapReached = true }
                return stdoutCapReached
            } else {
                let room = max(0, cap - stderr.count)
                if room > 0 { stderr.append(data.prefix(room)) }
                if data.count > room { stderrCapReached = true }
                return stderrCapReached
            }
        }

        func rendered() -> (stdout: String, stderr: String) {
            (String(data: stdout, encoding: .utf8) ?? "",
             String(data: stderr, encoding: .utf8) ?? "")
        }

        func capFlags() -> (stdout: Bool, stderr: Bool) {
            (stdoutCapReached, stderrCapReached)
        }
    }

    private func startCommandExecSession(id: RequestId,
                                         processId: String,
                                         command: [String],
                                         cwd: String,
                                         environment: [String: String],
                                         timeoutMs: Int?,
                                         outputBytesCap: Int?,
                                         streamOutput: Bool,
                                         streamStdin: Bool,
                                         tty: Bool,
                                         size: JSONValue?,
                                         conn: any ClientConnection) async {
        let key = CommandExecSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                        processId: processId)
        guard commandExecSessions[key] == nil else {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec processId already exists: \(processId)"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        let stdoutPipe: Pipe?
        let stderrPipe: Pipe?
        var stdinPipe: Pipe?
        let ptyMaster: FileHandle?
        let ptySlaves: [FileHandle]
        if tty {
            do {
                let handles = try Self.openPty(size: size)
                ptyMaster = handles.master
                ptySlaves = handles.slaves
                process.standardInput = handles.slaves[0]
                process.standardOutput = handles.slaves[1]
                process.standardError = handles.slaves[2]
                stdinPipe = nil
                stdoutPipe = nil
                stderrPipe = nil
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to create command/exec pty: \(error.localizedDescription)"))
                return
            }
        } else {
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            stdoutPipe = out
            stderrPipe = err
            ptyMaster = nil
            ptySlaves = []
        }
        if streamStdin && !tty {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let output = CommandExecOutputBuffer(cap: outputBytesCap)
        let exitContinuation = ProcessExitContinuation()
        process.terminationHandler = { p in
            exitContinuation.resolve(p.terminationStatus)
        }

        do {
            try process.run()
            ptySlaves.forEach { try? $0.close() }
            commandExecSessions[key] = CommandExecProcess(
                process: process,
                stdin: tty ? ptyMaster : stdinPipe?.fileHandleForWriting,
                ptyMaster: ptyMaster,
                stdinCloseable: !tty)
        } catch {
            try? ptyMaster?.close()
            ptySlaves.forEach { try? $0.close() }
            await conn.send(WireError.internalError(id: id, "failed to spawn command/exec: \(error)"))
            return
        }

        if let ptyMaster {
            drainCommandExec(handle: ptyMaster, processId: processId, stream: "stdout",
                             streamOutput: streamOutput, output: output, conn: conn)
        } else {
            if let stdoutPipe {
                drainCommandExec(pipe: stdoutPipe, processId: processId, stream: "stdout",
                                 streamOutput: streamOutput, output: output, conn: conn)
            }
            if let stderrPipe {
                drainCommandExec(pipe: stderrPipe, processId: processId, stream: "stderr",
                                 streamOutput: streamOutput, output: output, conn: conn)
            }
        }

        Task { [weak self, conn, id, key, process, output, timeoutMs, streamOutput] in
            guard let self else { return }
            let exitCode = await waitForCommandExecExit(process: process,
                                                        exitContinuation: exitContinuation,
                                                        timeoutMs: timeoutMs)
            let rendered = await output.rendered()
            await self.finishCommandExecSession(
                key: key, conn: conn, id: id,
                exitCode: exitCode,
                stdout: streamOutput ? "" : rendered.stdout,
                stderr: streamOutput ? "" : rendered.stderr)
        }
    }

    private final class ProcessExitContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []
        func resolve(_ value: Int32) {
            lock.lock()
            guard status == nil else {
                lock.unlock()
                return
            }
            status = value
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in pending { waiter.resume(returning: value) }
        }
        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let status {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    private func waitForCommandExecExit(process: Process,
                                        exitContinuation: ProcessExitContinuation,
                                        timeoutMs: Int?) async -> Int32 {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await exitContinuation.wait() }
            if let timeoutMs {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(timeoutMs))
                    if process.isRunning { process.terminate() }
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            return await exitContinuation.wait()
        }
    }

    private func drainCommandExec(pipe: Pipe,
                                  processId: String,
                                  stream: String,
                                  streamOutput: Bool,
                                  output: CommandExecOutputBuffer,
                                  conn: any ClientConnection) {
        drainCommandExec(handle: pipe.fileHandleForReading, processId: processId,
                         stream: stream, streamOutput: streamOutput,
                         output: output, conn: conn)
    }

    private func drainCommandExec(handle: FileHandle,
                                  processId: String,
                                  stream: String,
                                  streamOutput: Bool,
                                  output: CommandExecOutputBuffer,
                                  conn: any ClientConnection) {
        Task.detached { [conn] in
            while true {
                let data = (try? handle.read(upToCount: 65_536)) ?? Data()
                if data.isEmpty { break }
                let capReached = await output.append(data, stream: stream)
                if streamOutput {
                    await conn.send(.notification(JSONRPCNotification(
                        method: "command/exec/outputDelta",
                        params: .object([
                            "processId": .string(processId),
                            "stream": .string(stream),
                            "deltaBase64": .string(data.base64EncodedString()),
                            "capReached": .bool(capReached),
                        ]))))
                }
            }
        }
    }

    private func finishCommandExecSession(key: CommandExecSessionKey,
                                          conn: any ClientConnection,
                                          id: RequestId,
                                          exitCode: Int32,
                                          stdout: String,
                                          stderr: String) async {
        commandExecSessions[key] = nil
        await reply(conn, id, .object([
            "exitCode": .int(Int64(exitCode)),
            "stdout": .string(stdout),
            "stderr": .string(stderr),
        ]))
    }

    private func handleCommandExecWrite(id: RequestId,
                                        params: JSONValue?,
                                        conn: any ClientConnection) async {
        guard let processId = params?["processId"]?.stringValue, !processId.isEmpty else {
            await conn.send(WireError.invalidRequest(id: id, "command/exec/write requires processId"))
            return
        }
        let key = CommandExecSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                        processId: processId)
        guard let session = commandExecSessions[key] else {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec/write unknown processId: \(processId)"))
            return
        }
        if let encoded = params?["deltaBase64"]?.stringValue {
            guard let data = Data(base64Encoded: encoded) else {
                await conn.send(WireError.invalidRequest(
                    id: id, "command/exec/write deltaBase64 must be valid base64"))
                return
            }
            session.stdin?.write(data)
        }
        if params?["closeStdin"]?.boolValue == true {
            if session.stdinCloseable {
                try? session.stdin?.close()
            }
        }
        await reply(conn, id, .object([:]))
    }

    private func handleCommandExecTerminate(id: RequestId,
                                            params: JSONValue?,
                                            conn: any ClientConnection) async {
        guard let processId = params?["processId"]?.stringValue, !processId.isEmpty else {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec/terminate requires processId"))
            return
        }
        let key = CommandExecSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                        processId: processId)
        guard let session = commandExecSessions[key] else {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec/terminate unknown processId: \(processId)"))
            return
        }
        if session.process.isRunning {
            session.process.terminate()
        }
        await reply(conn, id, .object([:]))
    }

    private func handleCommandExecResize(id: RequestId,
                                         params: JSONValue?,
                                         conn: any ClientConnection) async {
        guard let processId = params?["processId"]?.stringValue, !processId.isEmpty else {
            await conn.send(WireError.invalidRequest(id: id, "command/exec/resize requires processId"))
            return
        }
        let key = CommandExecSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                        processId: processId)
        guard commandExecSessions[key] != nil else {
            await conn.send(WireError.invalidRequest(
                id: id, "command/exec/resize unknown processId: \(processId)"))
            return
        }
        if let master = commandExecSessions[key]?.ptyMaster {
            do {
                try Self.resizePty(master.fileDescriptor, size: params?["size"] ?? params)
            } catch {
                await conn.send(WireError.invalidRequest(
                    id: id, "command/exec/resize failed: \(error.localizedDescription)"))
                return
            }
        }
        await reply(conn, id, .object([:]))
    }

    private func terminateCommandExecSessions(connection: ObjectIdentifier) async {
        let keys = commandExecSessions.keys.filter { $0.connection == connection }
        for key in keys {
            if let session = commandExecSessions.removeValue(forKey: key),
               session.process.isRunning {
                session.process.terminate()
            }
        }
    }

    private func handleProcessRequest(id: RequestId, method: String,
                                      params: JSONValue?,
                                      conn: any ClientConnection) async -> Bool {
        switch method {
        case "process/spawn":
            await handleProcessSpawn(id: id, params: params, conn: conn)
            return true
        case "process/writeStdin":
            await handleProcessWriteStdin(id: id, params: params, conn: conn)
            return true
        case "process/kill":
            await handleProcessKill(id: id, params: params, conn: conn)
            return true
        case "process/resizePty":
            await handleProcessResizePty(id: id, params: params, conn: conn)
            return true
        default:
            return false
        }
    }

    private func handleProcessSpawn(id: RequestId,
                                    params: JSONValue?,
                                    conn: any ClientConnection) async {
        guard let params else {
            await conn.send(WireError.invalidRequest(id: id, "process/spawn requires params"))
            return
        }
        let processHandle = params["processHandle"]?.stringValue
            ?? params["processId"]?.stringValue
            ?? params["id"]?.stringValue
        guard let processHandle, !processHandle.isEmpty else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/spawn requires processHandle"))
            return
        }
        guard let commandValues = params["command"]?.arrayValue else {
            await conn.send(WireError.invalidRequest(id: id, "process/spawn requires command"))
            return
        }
        let command = commandValues.compactMap(\.stringValue)
        guard command.count == commandValues.count, !command.isEmpty else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/spawn command must be a non-empty array of strings"))
            return
        }
        let tty = params["tty"]?.boolValue == true
        // `tty` implies `streamStdoutStderr` (upstream process.rs:40). Otherwise
        // streaming is opt-in (`streamStdoutStderr`, default false → buffered).
        let streamOutput = tty || params["streamStdoutStderr"]?.boolValue == true
        // `outputBytesCap` is a double-option: omitted → server default (1 MiB);
        // explicit JSON `null` → cap disabled. Mirror command/exec.
        let outputCap: Int?
        if let capValue = params["outputBytesCap"] {
            outputCap = capValue.isNull ? nil : capValue.intValue.map(Int.init)
        } else {
            outputCap = 1_048_576
        }

        let key = ProcessSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                    processHandle: processHandle)
        guard processSessions[key] == nil else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/spawn processHandle already exists: \(processHandle)"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(
            fileURLWithPath: params["cwd"]?.stringValue
                ?? FileManager.default.currentDirectoryPath)
        process.environment = commandEnvironment(overrides: params["env"])
        let stdoutPipe: Pipe?
        let stderrPipe: Pipe?
        let stdinPipe: Pipe?
        let ptyMaster: FileHandle?
        let ptySlaves: [FileHandle]
        if tty {
            do {
                let handles = try Self.openPty(size: params["size"])
                ptyMaster = handles.master
                ptySlaves = handles.slaves
                process.standardInput = handles.slaves[0]
                process.standardOutput = handles.slaves[1]
                process.standardError = handles.slaves[2]
                stdinPipe = nil
                stdoutPipe = nil
                stderrPipe = nil
            } catch {
                await conn.send(WireError.internalError(
                    id: id, "failed to create process pty: \(error.localizedDescription)"))
                return
            }
        } else {
            let out = Pipe()
            let err = Pipe()
            let input = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input
            stdoutPipe = out
            stderrPipe = err
            stdinPipe = input
            ptyMaster = nil
            ptySlaves = []
        }
        let exitContinuation = ProcessExitContinuation()
        process.terminationHandler = { p in
            exitContinuation.resolve(p.terminationStatus)
        }

        let output = CommandExecOutputBuffer(cap: outputCap)
        do {
            try process.run()
            ptySlaves.forEach { try? $0.close() }
            var outputTasks: [Task<Void, Never>] = []
            if let ptyMaster {
                outputTasks.append(drainProcessOutput(
                    handle: ptyMaster, processHandle: processHandle,
                    stream: "stdout", streamOutput: streamOutput,
                    output: output, conn: conn))
            } else {
                if let stdoutPipe {
                    outputTasks.append(drainProcessOutput(
                        pipe: stdoutPipe, processHandle: processHandle,
                        stream: "stdout", streamOutput: streamOutput,
                        output: output, conn: conn))
                }
                if let stderrPipe {
                    outputTasks.append(drainProcessOutput(
                        pipe: stderrPipe, processHandle: processHandle,
                        stream: "stderr", streamOutput: streamOutput,
                        output: output, conn: conn))
                }
            }
            processSessions[key] = ProcessSession(
                process: process,
                stdin: tty ? ptyMaster : stdinPipe?.fileHandleForWriting,
                ptyMaster: ptyMaster,
                stdinCloseable: !tty,
                outputTasks: outputTasks,
                output: output,
                streamOutput: streamOutput)
        } catch {
            try? ptyMaster?.close()
            ptySlaves.forEach { try? $0.close() }
            await conn.send(WireError.internalError(id: id, "failed to spawn process: \(error)"))
            return
        }
        Task { [weak self, conn, key, processHandle, exitContinuation] in
            let exitCode = await exitContinuation.wait()
            guard let self else { return }
            await self.finishProcessSession(
                key: key,
                conn: conn,
                processHandle: processHandle,
                exitCode: exitCode)
        }
        await reply(conn, id, .object([:]))
    }

    private func drainProcessOutput(pipe: Pipe,
                                    processHandle: String,
                                    stream: String,
                                    streamOutput: Bool,
                                    output: CommandExecOutputBuffer,
                                    conn: any ClientConnection) -> Task<Void, Never> {
        drainProcessOutput(handle: pipe.fileHandleForReading,
                           processHandle: processHandle,
                           stream: stream,
                           streamOutput: streamOutput,
                           output: output,
                           conn: conn)
    }

    private func drainProcessOutput(handle: FileHandle,
                                    processHandle: String,
                                    stream: String,
                                    streamOutput: Bool,
                                    output: CommandExecOutputBuffer,
                                    conn: any ClientConnection) -> Task<Void, Never> {
        Task.detached { [conn] in
            while true {
                let data = (try? handle.read(upToCount: 65_536)) ?? Data()
                if data.isEmpty { break }
                // Always feed the cap tracker so cap state is accurate; in
                // buffered mode the bytes are retained for process/exited, in
                // streaming mode they are forwarded and not retained.
                let capReached = await output.append(data, stream: stream)
                if streamOutput {
                    await conn.send(.notification(JSONRPCNotification(
                        method: "process/outputDelta",
                        params: .object([
                            "processHandle": .string(processHandle),
                            "stream": .string(stream),
                            "deltaBase64": .string(data.base64EncodedString()),
                            "capReached": .bool(capReached),
                        ]))))
                }
            }
        }
    }

    private func finishProcessSession(key: ProcessSessionKey,
                                      conn: any ClientConnection,
                                      processHandle: String,
                                      exitCode: Int32) async {
        let session = processSessions[key]
        processSessions[key] = nil
        if let session {
            for task in session.outputTasks {
                await task.value
            }
        }
        // Upstream ProcessExitedNotification always serializes stdout/stderr and
        // their cap flags (non-Option). In streaming mode stdout/stderr are
        // empty (bytes were delivered via outputDelta); in buffered mode they
        // carry the captured output. Cap flags reflect the tracked state either
        // way.
        let rendered = await session?.output.rendered() ?? (stdout: "", stderr: "")
        let caps = await session?.output.capFlags() ?? (stdout: false, stderr: false)
        let streamed = session?.streamOutput ?? true
        await conn.send(.notification(JSONRPCNotification(
            method: "process/exited",
            params: .object([
                "processHandle": .string(processHandle),
                "exitCode": .int(Int64(exitCode)),
                "stdout": .string(streamed ? "" : rendered.stdout),
                "stdoutCapReached": .bool(caps.stdout),
                "stderr": .string(streamed ? "" : rendered.stderr),
                "stderrCapReached": .bool(caps.stderr),
            ]))))
    }

    private func handleProcessWriteStdin(id: RequestId,
                                         params: JSONValue?,
                                         conn: any ClientConnection) async {
        guard let processHandle = processHandleParam(params) else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/writeStdin requires processHandle"))
            return
        }
        let key = ProcessSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                    processHandle: processHandle)
        guard let session = processSessions[key] else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/writeStdin unknown processHandle: \(processHandle)"))
            return
        }
        if let encoded = params?["deltaBase64"]?.stringValue {
            guard let data = Data(base64Encoded: encoded) else {
                await conn.send(WireError.invalidRequest(
                    id: id, "process/writeStdin deltaBase64 must be valid base64"))
                return
            }
            session.stdin?.write(data)
        }
        if params?["closeStdin"]?.boolValue == true {
            if session.stdinCloseable {
                try? session.stdin?.close()
            }
        }
        await reply(conn, id, .object([:]))
    }

    private func handleProcessKill(id: RequestId,
                                   params: JSONValue?,
                                   conn: any ClientConnection) async {
        guard let processHandle = processHandleParam(params) else {
            await conn.send(WireError.invalidRequest(id: id, "process/kill requires processHandle"))
            return
        }
        let key = ProcessSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                    processHandle: processHandle)
        guard let session = processSessions[key] else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/kill unknown processHandle: \(processHandle)"))
            return
        }
        if session.process.isRunning {
            session.process.terminate()
        }
        await reply(conn, id, .object([:]))
    }

    private func handleProcessResizePty(id: RequestId,
                                        params: JSONValue?,
                                        conn: any ClientConnection) async {
        guard let processHandle = processHandleParam(params) else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/resizePty requires processHandle"))
            return
        }
        let key = ProcessSessionKey(connection: ObjectIdentifier(conn as AnyObject),
                                    processHandle: processHandle)
        guard processSessions[key] != nil else {
            await conn.send(WireError.invalidRequest(
                id: id, "process/resizePty unknown processHandle: \(processHandle)"))
            return
        }
        if let master = processSessions[key]?.ptyMaster {
            do {
                try Self.resizePty(master.fileDescriptor, size: params?["size"] ?? params)
            } catch {
                await conn.send(WireError.invalidRequest(
                    id: id, "process/resizePty failed: \(error.localizedDescription)"))
                return
            }
        }
        await reply(conn, id, .object([:]))
    }

    private func processHandleParam(_ params: JSONValue?) -> String? {
        let value = params?["processHandle"]?.stringValue
            ?? params?["processId"]?.stringValue
            ?? params?["id"]?.stringValue
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func terminateProcessSessions(connection: ObjectIdentifier) async {
        let keys = processSessions.keys.filter { $0.connection == connection }
        for key in keys {
            if let session = processSessions.removeValue(forKey: key),
               session.process.isRunning {
                session.process.terminate()
            }
        }
    }

    private struct PtyHandles {
        let master: FileHandle
        let slaves: [FileHandle]
    }

    private static func openPty(size: JSONValue?) throws -> PtyHandles {
        #if canImport(Darwin)
        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(
            ws_row: UInt16(max(1, size?["rows"]?.intValue ?? size?["height"]?.intValue ?? 24)),
            ws_col: UInt16(max(1, size?["cols"]?.intValue ?? size?["columns"]?.intValue ?? size?["width"]?.intValue ?? 80)),
            ws_xpixel: 0,
            ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
            throw SimpleError("openpty failed with errno \(errno)")
        }
        let slaveIn = dup(slave)
        let slaveOut = dup(slave)
        let slaveErr = dup(slave)
        close(slave)
        guard slaveIn >= 0, slaveOut >= 0, slaveErr >= 0 else {
            if slaveIn >= 0 { close(slaveIn) }
            if slaveOut >= 0 { close(slaveOut) }
            if slaveErr >= 0 { close(slaveErr) }
            close(master)
            throw SimpleError("dup pty slave failed with errno \(errno)")
        }
        return PtyHandles(
            master: FileHandle(fileDescriptor: master, closeOnDealloc: true),
            slaves: [
                FileHandle(fileDescriptor: slaveIn, closeOnDealloc: true),
                FileHandle(fileDescriptor: slaveOut, closeOnDealloc: true),
                FileHandle(fileDescriptor: slaveErr, closeOnDealloc: true),
            ])
        #else
        throw SimpleError("PTY sessions are only implemented on Darwin")
        #endif
    }

    private static func resizePty(_ fd: Int32, size: JSONValue?) throws {
        #if canImport(Darwin)
        var ws = winsize(
            ws_row: UInt16(max(1, size?["rows"]?.intValue ?? size?["height"]?.intValue ?? 24)),
            ws_col: UInt16(max(1, size?["cols"]?.intValue ?? size?["columns"]?.intValue ?? size?["width"]?.intValue ?? 80)),
            ws_xpixel: 0,
            ws_ypixel: 0)
        guard ioctl(fd, TIOCSWINSZ, &ws) == 0 else {
            throw SimpleError("ioctl(TIOCSWINSZ) failed with errno \(errno)")
        }
        #else
        throw SimpleError("PTY resize is only implemented on Darwin")
        #endif
    }

    private func commandEnvironment(overrides: JSONValue?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let obj = overrides?.objectValue else { return env }
        for (key, value) in obj {
            if value.isNull {
                env.removeValue(forKey: key)
            } else if let s = value.stringValue {
                env[key] = s
            }
        }
        return env
    }

    private struct BufferedCommandResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private static func runBufferedCommand(_ command: [String],
                                           cwd: String,
                                           environment: [String: String],
                                           timeoutMs: Int?,
                                           outputBytesCap: Int?) throws -> BufferedCommandResult {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexkit-command-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let stdoutURL = temp.appendingPathComponent("stdout")
        let stderrURL = temp.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            sem.signal()
        }
        if let timeoutMs {
            let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
            if sem.wait(timeout: deadline) == .timedOut {
                process.terminate()
                if sem.wait(timeout: .now() + .seconds(2)) == .timedOut {
                    process.interrupt()
                }
            }
        } else {
            sem.wait()
        }
        try? stdout.close()
        try? stderr.close()
        return BufferedCommandResult(
            exitCode: process.terminationStatus,
            stdout: try readUTF8File(stdoutURL, cap: outputBytesCap),
            stderr: try readUTF8File(stderrURL, cap: outputBytesCap))
    }

    private static func readUTF8File(_ url: URL, cap: Int?) throws -> String {
        let data = try Data(contentsOf: url)
        let capped: Data
        if let cap, data.count > cap {
            capped = data.prefix(max(0, cap))
        } else {
            capped = data
        }
        return String(data: capped, encoding: .utf8)
            ?? String(decoding: capped, as: UTF8.self)
    }

    private func bindAndSubscribe(_ cfg: SessionConfig, _ conn: any ClientConnection) async {
        if subscriptions[cfg.threadId] != nil {
            if await supervisor.isBound(cfg.threadId) { return }
            subscriptions[cfg.threadId] = nil
        }
        let v1 = false
        let sinkId = await supervisor.ensureWorker(
            cfg,
            requestAttestation: caps.requestAttestation,
            onNotification: { notification in
                Task { await conn.send(notification.toMessage(v1Alias: v1)) }
            },
            onServerRequest: { req in
                Task { await conn.send(req.toMessage()) }
            })
        subscriptions[cfg.threadId] = sinkId
        await skillsChangeWatchManager.watch(conn: conn, threadId: cfg.threadId,
                                             roots: Self.skillWatchRoots(codexHome: codexHome,
                                                                         cwd: cfg.cwd))
    }

    private static func skillWatchRoots(codexHome: String, cwd: String) -> [String] {
        [
            codexHome + "/skills",
            cwd + "/.codex/skills",
        ]
    }

    private func presentFields(_ params: JSONValue?) -> [String] {
        guard let obj = params?.objectValue else { return [] }
        var fields = Array(obj.keys)
        // Upstream's `ExperimentalApi::experimental_reason` recurses through the
        // entire typed params structure (common.rs `inspect_params: true`), so
        // an `AskForApproval::Granular` variant anywhere — top-level
        // `approvalPolicy`, inside `config.approvalPolicy`, inside any
        // `config.profiles.*.approvalPolicy`, or inside a
        // `configRequirements.allowedApprovalPolicies[]` element — is gated with
        // the fixed reason `askForApproval.granular`
        // (app-server-protocol/src/protocol/v2/shared.rs:168, tests.rs:1481-1745).
        // Emit the `"askForApproval=granular"` enum-variant marker whenever the
        // granular variant is present so the gate fires for non-experimental
        // connections instead of silently dropping the granular value.
        if Self.containsGranularApprovalPolicy(params) {
            fields.append("askForApproval=granular")
        }
        return fields
    }

    /// Recursively detects an `AskForApproval::Granular` variant carried by any
    /// `approvalPolicy` / `askForApproval` field (top-level or nested under
    /// `config` / `profiles` / `allowedApprovalPolicies`). The granular variant
    /// serialises externally-tagged as `{"granular": {…}}`; the port also
    /// accepts a bare `"granular"` string for the same variant
    /// (ProtocolModel/Approvals.swift), so both forms are treated as granular.
    static func containsGranularApprovalPolicy(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .object(let obj):
            for (key, child) in obj {
                if key == "approvalPolicy" || key == "askForApproval",
                   isGranularVariant(child) {
                    return true
                }
                if containsGranularApprovalPolicy(child) { return true }
            }
            return false
        case .array(let arr):
            for child in arr where containsGranularApprovalPolicy(child) { return true }
            return false
        default:
            return false
        }
    }

    /// True when `value` is the `AskForApproval::Granular` variant, in either
    /// the externally-tagged object form `{"granular": …}` or the bare-string
    /// convenience form `"granular"`.
    private static func isGranularVariant(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let s): return s == "granular"
        case .object(let o): return o["granular"] != nil
        default: return false
        }
    }
    private func platformFamily() -> String {
        #if os(macOS)
        return "Darwin"
        #elseif os(Linux)
        return "Linux"
        #else
        return "Unknown"
        #endif
    }
    private func platformOs() -> String {
        #if os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #else
        return "unknown"
        #endif
    }
}
