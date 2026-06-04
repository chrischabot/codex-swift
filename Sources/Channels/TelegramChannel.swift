import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// DEFERRED ITEM 5 (docs/extensions/ARCHITECTURE.md §12 Phase 4): the production
// Telegram transport scaffold. A `Channel` that long-polls the Telegram Bot API
// `getUpdates` endpoint, maps each update into an `InboundMessage`, runs it as a
// turn via `host.deliver`, and relays the reply via `sendMessage`.
//
// SECURITY (lesson L5): the sender's identity is SERVER-stamped from Telegram's
// AUTHENTICATED transport id (`message.from.id`) versus the operator owner
// allowlist — NEVER from message content. `senderIsOwner` therefore comes from
// `ChannelIdentity.normalize`, not from anything in the message text, which is
// treated as UNTRUSTED user content. The pure `mapTelegramUpdate` function below
// is the single, deterministically-tested seam that enforces this.
//
// TRANSPORT-AGNOSTIC: this channel drives `any ChannelHost`, so it composes with
// either `EngineChannelHost` (single engine / tests) or a future
// supervisor-backed host. It introduces no `Channels`→`Supervisor` dependency.
//
// OPT-IN: constructed only when `[channels.telegram]` config + a bot token are
// present; default OFF (`TelegramConfig.load` returns nil otherwise).
//
// LIVE VERIFICATION IS EXTERNALLY BLOCKED: a real run needs a @BotFather bot
// token and outbound network to api.telegram.org, neither available here. The
// update→InboundMessage mapping and owner-stamping are unit-tested with canned
// `getUpdates` JSON and need no network (see Tests/ChannelsTests).

// MARK: - Wire model (the Telegram Bot API `getUpdates` response shape)

/// The top-level `getUpdates` envelope: `{ ok: Bool, result: [Update] }`.
/// `Decodable` IS the schema — we decode exactly the fields we consume and
/// ignore the rest (Telegram adds fields freely; unknown keys are dropped).
public struct TelegramGetUpdatesResponse: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let result: [TelegramUpdate]
    public init(ok: Bool, result: [TelegramUpdate]) { self.ok = ok; self.result = result }
}

/// One Telegram update. `update_id` is a monotonically increasing cursor; we
/// advance the long-poll `offset` to `max(update_id) + 1` to acknowledge.
/// `message` is optional — non-message updates (edited messages, callbacks,
/// channel posts, …) have no `message` and are skipped by the mapper.
public struct TelegramUpdate: Decodable, Sendable, Equatable {
    public let updateId: Int64
    public let message: TelegramMessage?
    public init(updateId: Int64, message: TelegramMessage?) {
        self.updateId = updateId; self.message = message
    }
    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
    }
}

/// A Telegram message. `from` carries the AUTHENTICATED sender (we use its
/// numeric `id` as the server-stamped sender identity); `chat` is the
/// conversation; `text` is the UNTRUSTED user content (absent for non-text
/// messages such as photos/stickers, which the mapper skips).
public struct TelegramMessage: Decodable, Sendable, Equatable {
    public let from: TelegramUser?
    public let chat: TelegramChat
    public let text: String?
    public init(from: TelegramUser?, chat: TelegramChat, text: String?) {
        self.from = from; self.chat = chat; self.text = text
    }
}

/// The authenticated sender. `id` is a stable numeric Telegram user id; it is
/// the ONLY trustworthy identity signal (the transport authenticated it). We
/// stringify it for `ChannelIdentity` (which keys owners by `String`).
public struct TelegramUser: Decodable, Sendable, Equatable {
    public let id: Int64
    public init(id: Int64) { self.id = id }
}

/// The conversation. `id` is the chat id (positive for a private chat, negative
/// for groups/channels); it becomes the `conversationId` → engine `ThreadId`.
public struct TelegramChat: Decodable, Sendable, Equatable {
    public let id: Int64
    public init(id: Int64) { self.id = id }
}

// MARK: - The pure, deterministically-tested mapping

/// Map ONE Telegram update into an `InboundMessage`, or `nil` if the update is
/// not a routable text message.
///
/// This is the security-critical seam and is intentionally pure (no I/O, no
/// global state) so it is exhaustively unit-testable:
///
/// - `channelId` is the constant `"telegram"`.
/// - `conversationId` is the chat id (`message.chat.id`).
/// - `senderId` is the AUTHENTICATED `message.from.id` — never anything parsed
///   from the message text.
/// - `senderIsOwner` is decided by `identity.normalize` (owner allowlist
///   membership of `senderId`), so a crafted message claiming ownership CANNOT
///   forge it (lesson L5).
/// - `text` is preserved verbatim as UNTRUSTED content.
///
/// Returns `nil` (skip) when the update has no `message`, no `from` (e.g. an
/// anonymous channel post — we cannot authenticate a sender, so we refuse to
/// route it), or no `text` (non-text messages we do not yet handle).
public func mapTelegramUpdate(_ update: TelegramUpdate,
                              identity: ChannelIdentity) -> InboundMessage? {
    guard let message = update.message else { return nil }
    guard let from = message.from else { return nil }
    guard let text = message.text else { return nil }
    return identity.normalize(channelId: TelegramChannel.channelId,
                              conversationId: String(message.chat.id),
                              senderId: String(from.id),
                              text: text)
}

/// Map a whole `getUpdates` batch: the routable `InboundMessage`s (skipping
/// non-text / sender-less updates) plus the next long-poll `offset`
/// (`max(update_id) + 1`, or `nil` when the batch is empty → keep the prior
/// offset). Pure → the loop's cursor arithmetic is unit-testable end to end.
public func mapTelegramBatch(_ response: TelegramGetUpdatesResponse,
                             identity: ChannelIdentity)
    -> (messages: [(update: TelegramUpdate, inbound: InboundMessage)], nextOffset: Int64?) {
    var out: [(update: TelegramUpdate, inbound: InboundMessage)] = []
    var maxId: Int64? = nil
    for u in response.result {
        maxId = max(maxId ?? u.updateId, u.updateId)
        if let inbound = mapTelegramUpdate(u, identity: identity) {
            out.append((u, inbound))
        }
    }
    return (out, maxId.map { $0 + 1 })
}

// MARK: - Config (opt-in: `[channels.telegram]` + bot token)

/// Parsed `[channels.telegram]` configuration. Built only when the feature is
/// enabled AND a bot token is resolvable; otherwise `load` returns `nil` so the
/// channel is never constructed (default OFF).
public struct TelegramConfig: Sendable, Equatable {
    /// The bot token (from @BotFather). Resolved from `TELEGRAM_BOT_TOKEN` (or a
    /// configured env var name) — NEVER persisted in config TOML to keep the
    /// secret off disk. Held in memory for the channel's lifetime only.
    public let botToken: String
    /// Numeric Telegram user ids allowed to drive privileged actions (owner
    /// allowlist). Stringified to match `ChannelIdentity.owners`.
    public let owners: Set<String>
    /// Long-poll hold time (seconds) passed as the `getUpdates?timeout=` query
    /// param — the server holds the connection open up to this long.
    public let pollTimeoutSeconds: Int
    /// Telegram Bot API base (override only for testing/self-hosted gateways).
    public let apiBase: String

    public init(botToken: String, owners: Set<String>,
                pollTimeoutSeconds: Int = 30,
                apiBase: String = "https://api.telegram.org") {
        self.botToken = botToken; self.owners = owners
        self.pollTimeoutSeconds = pollTimeoutSeconds; self.apiBase = apiBase
    }

    /// Build a `ChannelIdentity` (owner allowlist) from this config.
    public var channelIdentity: ChannelIdentity { ChannelIdentity(owners: owners) }

    /// Resolve config from already-extracted `[channels.telegram]` values + an
    /// environment. Returns `nil` (feature OFF) when the channel must not start:
    /// not `enabled`, or no resolvable bot token. The secret is read from
    /// `env[botTokenEnvVar]` (default `TELEGRAM_BOT_TOKEN`) and NEVER from the
    /// config TOML, so it does not land on disk.
    ///
    /// This is a PURE function of its inputs (the composition root — which owns
    /// the `Config` dependency — extracts the raw values and passes them here),
    /// so secret-resolution and the enable gate are deterministically testable
    /// without importing `Config` into the `Channels` target.
    ///
    /// - Parameters:
    ///   - enabled: the `[channels.telegram].enabled` flag (default OFF).
    ///   - botTokenEnvVar: env var name holding the token (config-overridable).
    ///   - owners: numeric Telegram user ids from `[channels.telegram].owners`.
    ///   - pollTimeoutSeconds: `[channels.telegram].poll_timeout_seconds`.
    ///   - apiBase: override only for testing/self-hosted gateways.
    ///   - env: the process environment (injectable for tests).
    public static func load(enabled: Bool,
                            botTokenEnvVar: String? = nil,
                            owners: [String] = [],
                            pollTimeoutSeconds: Int? = nil,
                            apiBase: String? = nil,
                            env: [String: String]) -> TelegramConfig? {
        guard enabled else { return nil }
        let envVar = (botTokenEnvVar?.isEmpty == false ? botTokenEnvVar! : "TELEGRAM_BOT_TOKEN")
        guard let token = env[envVar], !token.isEmpty else { return nil }
        return TelegramConfig(botToken: token,
                              owners: Set(owners),
                              pollTimeoutSeconds: pollTimeoutSeconds ?? 30,
                              apiBase: apiBase ?? "https://api.telegram.org")
    }
}

// MARK: - The transport

/// A Telegram Bot API `Channel`: long-polls `getUpdates`, maps each text update
/// into an `InboundMessage` (server-stamped identity), runs it via the host, and
/// relays the reply via `sendMessage`. Text-only inbound/outbound to start
/// (lesson L7 — add reactions/attachments only when needed).
public actor TelegramChannel: Channel {
    /// Stable channel id stamped onto every `InboundMessage`.
    public static let channelId = "telegram"
    public nonisolated var id: String { TelegramChannel.channelId }

    private let config: TelegramConfig
    private let identity: ChannelIdentity
    private let session: URLSession
    /// Reuse the long-poll connection but never share cookies / cache / creds.
    private let httpTimeout: TimeInterval

    /// Long-poll cursor: the next `offset` to request. Advanced past each
    /// acknowledged batch.
    private var offset: Int64 = 0
    private var pollTask: Task<Void, Never>?

    /// - Parameter session: injectable for tests (a `URLSession` whose
    ///   configuration mounts a `URLProtocol` stub). Production passes a default
    ///   ephemeral session.
    public init(config: TelegramConfig, session: URLSession? = nil) {
        self.config = config
        self.identity = config.channelIdentity
        // Network read timeout must exceed the long-poll hold so the SERVER, not
        // the client, ends an idle poll (avoids spurious client-side timeouts).
        self.httpTimeout = TimeInterval(config.pollTimeoutSeconds) + 15
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.waitsForConnectivity = false
            cfg.timeoutIntervalForRequest = TimeInterval(config.pollTimeoutSeconds) + 15
            cfg.timeoutIntervalForResource = TimeInterval(config.pollTimeoutSeconds) + 30
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            cfg.urlCache = nil
            cfg.httpCookieStorage = nil
            cfg.urlCredentialStorage = nil
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: Channel

    /// Attach to a host and run the long-poll loop until `stop()` (or task
    /// cancellation). The loop SHAPE: GET `getUpdates?offset=&timeout=` →
    /// `mapTelegramBatch` → for each inbound, `await host.deliver` then POST the
    /// reply via `sendMessage` → advance `offset`. Transport errors back off
    /// briefly and retry rather than tearing the channel down.
    public func start(_ host: any ChannelHost) async throws {
        // Idempotent: a second start replaces the prior loop.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runLoop(host)
        }
    }

    /// Cancel the long-poll task. In-flight `getUpdates` aborts via URLSession
    /// cancellation (the dataTask completes with NSURLErrorCancelled, which the
    /// loop treats as a benign shutdown).
    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: long-poll loop (the SHAPE)

    private func runLoop(_ host: any ChannelHost) async {
        while !Task.isCancelled {
            switch await fetchUpdates(offset: offset) {
            case .failure:
                // Transient transport/decoding error — brief backoff, retry.
                // (A real run would also surface auth/4xx; the scaffold treats
                // all failures as retryable and lets `stop()` end the loop.)
                try? await Task.sleep(for: .seconds(2))
                continue
            case .success(let response):
                let (batch, nextOffset) = mapTelegramBatch(response, identity: identity)
                for (_, inbound) in batch {
                    if Task.isCancelled { return }
                    let reply = await host.deliver(inbound)
                    // Relay the agent's reply text (skip empty tool-only turns).
                    let outgoing = outgoingText(for: reply)
                    if !outgoing.isEmpty {
                        _ = await sendMessage(chatId: inbound.conversationId, text: outgoing)
                    }
                }
                if let nextOffset { offset = nextOffset }
            }
        }
    }

    /// Choose the text to send back. A completed turn relays its text; a
    /// non-completed turn (timeout/failed/interrupted) with no text surfaces a
    /// minimal status note so the user isn't left silent. Pure helper → easy to
    /// adjust without touching the loop.
    nonisolated func outgoingText(for reply: ChannelReply) -> String {
        if !reply.text.isEmpty { return reply.text }
        switch reply.status {
        case "completed": return ""          // genuine empty (tool-only) turn
        case "timeout":   return "(the agent did not respond in time)"
        case "failed":    return "(the agent run failed)"
        case "interrupted": return "(the agent run was interrupted)"
        default:          return ""
        }
    }

    // MARK: HTTP (Bot API)

    /// GET `getUpdates?offset=<offset>&timeout=<pollTimeout>` and decode the
    /// envelope. The `timeout` query param is the long-poll hold (server-side).
    func fetchUpdates(offset: Int64) async -> Result<TelegramGetUpdatesResponse, TelegramTransportError> {
        var comps = URLComponents(string: "\(config.apiBase)/bot\(config.botToken)/getUpdates")
        comps?.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "timeout", value: String(config.pollTimeoutSeconds)),
        ]
        guard let url = comps?.url else {
            return .failure(.invalidURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = httpTimeout
        switch await perform(req) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            do {
                let decoded = try JSONDecoder().decode(TelegramGetUpdatesResponse.self, from: data)
                return .success(decoded)
            } catch {
                return .failure(.decode(String(describing: error)))
            }
        }
    }

    /// POST `sendMessage` with `{ chat_id, text }`. Best-effort relay — a failed
    /// send is reported but does not abort the loop.
    @discardableResult
    func sendMessage(chatId: String, text: String) async -> Result<Void, TelegramTransportError> {
        guard let url = URL(string: "\(config.apiBase)/bot\(config.botToken)/sendMessage") else {
            return .failure(.invalidURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = httpTimeout
        // chat_id may be a numeric string; the Bot API accepts both string and
        // integer. We encode the chat id verbatim (it came from chat.id).
        let payload: [String: String] = ["chat_id": chatId, "text": text]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .failure(.decode(String(describing: error)))
        }
        switch await perform(req) {
        case .failure(let e): return .failure(e)
        case .success: return .success(())
        }
    }

    /// Run one request via `URLSession`, propagating `Task.cancel()` into the
    /// in-flight dataTask (the WebSearch pattern: continuation + cancellation
    /// handler so `stop()` aborts a held long-poll within ~tens of ms). The bot
    /// token travels in the URL path (Bot API convention) and never on a
    /// child-process argv — there is no child process.
    private func perform(_ req: URLRequest) async -> Result<Data, TelegramTransportError> {
        let box = TelegramTaskBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<Data, TelegramTransportError>, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: .failure(.cancelled)); return
                }
                let task = session.dataTask(with: req) { data, resp, err in
                    if let err = err {
                        let ns = err as NSError
                        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                            cont.resume(returning: .failure(.cancelled)); return
                        }
                        cont.resume(returning: .failure(.transport(err.localizedDescription))); return
                    }
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let snippet = String(decoding: (data ?? Data()).prefix(300), as: UTF8.self)
                        cont.resume(returning: .failure(.http(status: http.statusCode, body: snippet))); return
                    }
                    cont.resume(returning: .success(data ?? Data()))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Sendable box so the non-Sendable `URLSessionDataTask` can be referenced
    /// from the cancellation handler under Swift 6 isolation (mirrors
    /// `WebHTTP.TaskBox`).
    private final class TelegramTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func set(_ t: URLSessionDataTask) {
            lock.lock(); defer { lock.unlock() }
            if cancelled { t.cancel() } else { task = t }
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            task?.cancel()
        }
    }
}

// ADDONS.md #2/#1 — surface Telegram's `sendMessage` through the shared OUTBOUND
// seam so the same transport that runs INBOUND turns is also a delivery SINK for
// push (#7), cron (#6), and media (#8). Text-only for now (Bot API `sendMessage`);
// photo/document attachments are a follow-on (`sendPhoto`/`sendDocument`).
extension TelegramChannel: ChannelOutbound {
    public nonisolated var capabilities: SinkCapabilities {
        // Telegram caps a message at 4096 UTF-16 chars; we send text only.
        SinkCapabilities(supportsAttachments: false, maxTextBytes: 4096)
    }

    public func send(_ message: OutboundMessage) async -> OutboundReceipt {
        switch await sendMessage(chatId: message.conversationId, text: message.text) {
        case .success:        return .delivered
        case .failure(let e): return .failed("\(e)")
        }
    }
}

/// Transport-layer error for the scaffold (the loop treats all of these as
/// retryable; `stop()`/cancellation is the only clean exit).
public enum TelegramTransportError: Error, Sendable, Equatable {
    case invalidURL
    case cancelled
    case transport(String)
    case http(status: Int, body: String)
    case decode(String)
}
