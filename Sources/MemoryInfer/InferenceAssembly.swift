import Foundation
import InfraPrimitives

/// Top-level configuration for the MemoryInfer subsystem. Picks between the
/// MLX local provider and the remote OpenAI-compatible provider, applies a
/// concurrency cap, and exposes a single ready-made provider to callers.
public struct MemoryInferConfig: Sendable {
    public enum Backend: Sendable {
        case mock
        case mlxLocal
        case remote
    }
    public var backend: Backend
    public var embeddingDimension: Int
    public var extractInFlight: Int
    public var embedInFlight: Int
    public var rerankInFlight: Int

    public init(backend: Backend = .mock,
                embeddingDimension: Int = 768,
                extractInFlight: Int = 4,
                embedInFlight: Int = 8,
                rerankInFlight: Int = 4) {
        self.backend = backend
        self.embeddingDimension = embeddingDimension
        self.extractInFlight = extractInFlight
        self.embedInFlight = embedInFlight
        self.rerankInFlight = rerankInFlight
    }
}

/// Builds a ready-to-use `LocalInferenceProvider`. The caller can pass an
/// optional remote-text/embedding closure pair to bind the remote provider to
/// a real endpoint; when omitted, the assembler returns the mock provider so
/// downstream wiring is always satisfied.
public func makeInferenceProvider(
    _ config: MemoryInferConfig,
    remoteText: RemoteOpenAICompatibleProvider.TextCall? = nil,
    remoteEmbedding: RemoteOpenAICompatibleProvider.EmbeddingCall? = nil,
    remoteLogprob: RemoteOpenAICompatibleProvider.LogprobCall? = nil
) async -> any LocalInferenceProvider {
    switch config.backend {
    case .mock:
        return MockInferenceProvider(embeddingDimension: config.embeddingDimension)
    case .mlxLocal:
        if MLXLocalProvider.isAvailable {
            return MLXLocalProvider(embeddingDimension: config.embeddingDimension)
        }
        return MockInferenceProvider(embeddingDimension: config.embeddingDimension)
    case .remote:
        guard let t = remoteText, let e = remoteEmbedding, let l = remoteLogprob else {
            return MockInferenceProvider(embeddingDimension: config.embeddingDimension)
        }
        return RemoteOpenAICompatibleProvider(
            embeddingDimension: config.embeddingDimension,
            textCall: t, embeddingCall: e, logprobCall: l)
    }
}

/// Concurrency-capping wrapper. Wraps any `LocalInferenceProvider` with a
/// `TokenBucket` per operation kind. Mirrors the hardening §7 discipline:
/// extractor in-flight ≤ 4, embedder ≤ 8, rerank ≤ 4 by default.
public actor BoundedInferenceProvider: LocalInferenceProvider {
    nonisolated public let embeddingDimension: Int
    private let inner: any LocalInferenceProvider
    private let extractGate: Semaphore
    private let embedGate: Semaphore
    private let rerankGate: Semaphore

    public init(_ inner: any LocalInferenceProvider, config: MemoryInferConfig) {
        self.inner = inner
        self.embeddingDimension = inner.embeddingDimension
        self.extractGate = Semaphore(limit: config.extractInFlight)
        self.embedGate = Semaphore(limit: config.embedInFlight)
        self.rerankGate = Semaphore(limit: config.rerankInFlight)
    }

    public func extract(_ batch: ChunkBatch,
                        schema: ExtractionSchema,
                        deadline: Deadline) async throws -> ExtractionResult {
        try await extractGate.acquire()
        defer { Task { await extractGate.release() } }
        return try await inner.extract(batch, schema: schema, deadline: deadline)
    }

    public func contextualize(_ chunk: Chunk,
                              in document: DocumentDigest,
                              deadline: Deadline) async throws -> String {
        try await extractGate.acquire()
        defer { Task { await extractGate.release() } }
        return try await inner.contextualize(chunk, in: document, deadline: deadline)
    }

    public func embed(_ texts: [String], deadline: Deadline) async throws -> [Embedding] {
        try await embedGate.acquire()
        defer { Task { await embedGate.release() } }
        return try await inner.embed(texts, deadline: deadline)
    }

    public func rerank(_ query: String,
                       candidates: [String],
                       deadline: Deadline) async throws -> [Float] {
        try await rerankGate.acquire()
        defer { Task { await rerankGate.release() } }
        return try await inner.rerank(query, candidates: candidates, deadline: deadline)
    }

    public func logprob(_ text: String,
                        given: String?,
                        deadline: Deadline) async throws -> Double {
        try await inner.logprob(text, given: given, deadline: deadline)
    }
}

/// Counting-semaphore actor with cancellation-safe acquire. Pure async/await
/// — no condition variables, no dispatch primitives. Fair FIFO via array
/// backed continuation queue; a cancelled waiter is removed from the queue
/// (or the next release skips it if it had already been parked then
/// cancelled) so a slot is never permanently lost to a dead task.
actor Semaphore {
    private struct Waiter {
        let id: UInt64
        let cont: CheckedContinuation<Void, any Error>
    }
    private var available: Int
    private var waiters: [Waiter] = []
    private var cancelled: Set<UInt64> = []
    private var nextId: UInt64 = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.available = limit
    }

    /// Park until a slot is available. Throws `CancellationError` if the
    /// surrounding Task is cancelled before/while parked; in that case no
    /// slot is consumed, so callers must not release on the cancellation
    /// path. The standard pattern is:
    ///
    ///     try await sem.acquire()
    ///     defer { Task { await sem.release() } }
    ///
    /// `defer` only runs when acquire returned without throwing, so the
    /// release/acquire counts stay balanced.
    func acquire() async throws {
        if Task.isCancelled { throw CancellationError() }
        if available > 0 {
            available -= 1
            return
        }
        let id = freshId()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, any Error>) in
                self.parkOrCancel(id: id, cont: cont)
            }
        } onCancel: {
            Task { await self.markCancelled(id) }
        }
    }

    /// Release one slot. Skips any cancelled-but-still-queued waiters and
    /// hands the slot to the next live waiter; if none exist, the available
    /// counter is incremented.
    func release() {
        while !waiters.isEmpty {
            let w = waiters.removeFirst()
            if cancelled.remove(w.id) != nil { continue }
            w.cont.resume()
            return
        }
        available += 1
    }

    private func parkOrCancel(id: UInt64, cont: CheckedContinuation<Void, any Error>) {
        if cancelled.remove(id) != nil {
            cont.resume(throwing: CancellationError())
            return
        }
        waiters.append(Waiter(id: id, cont: cont))
    }

    private func markCancelled(_ id: UInt64) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let w = waiters.remove(at: idx)
            w.cont.resume(throwing: CancellationError())
            return
        }
        // Cancel raced with park: record so the parker throws.
        cancelled.insert(id)
    }

    private func freshId() -> UInt64 { defer { nextId &+= 1 }; return nextId }
}
