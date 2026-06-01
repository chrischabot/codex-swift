import Foundation
import ModelClient

// Phase 3 of the extension layer (docs/extensions/ARCHITECTURE.md §7.4, D1):
// the local-LLM utility. A standalone schema-validated JSON sub-task service for
// cheap, frequent classification / labeling / scoring / routing — backed by an
// ordinary `ModelClient` the composition root points at a LOCAL endpoint
// (ollama / lmstudio / a small hosted model). It is exposed ONLY to extensions
// (e.g. Memory Wiki labeling/scoring); it NEVER participates in the agent's own
// model loop. "Escalation" is not model-routing here — an extension that needs
// more than a cheap pass simply spawns a real codex turn/subagent.

/// A cheap, JSON-only sub-task.
public struct SmallTask: Sendable, Equatable {
    /// The instruction / question.
    public var prompt: String
    /// Optional input payload appended after the prompt (the thing to classify).
    public var input: String
    /// System framing override (defaults to a strict JSON-only classifier frame).
    public var system: String?
    public init(prompt: String, input: String = "", system: String? = nil) {
        self.prompt = prompt; self.input = input; self.system = system
    }
}

public enum SmallModelError: Error, Sendable, Equatable {
    case empty
    case undecodable(String)
}

/// The utility surface handed to extensions.
public protocol SmallModelService: Sendable {
    /// Run a JSON-only sub-task and decode it into `T`. `T: Decodable` IS the
    /// schema — a non-decodable reply triggers one corrective retry before
    /// throwing, so callers get a validated value or an error, never garbage.
    func json<T: Decodable & Sendable>(_ task: SmallTask, as type: T.Type) async throws -> T
    /// Plain text completion (no JSON contract).
    func text(_ task: SmallTask) async throws -> String
}

/// `SmallModelService` backed by any `ModelClient` (reuses the existing
/// abstraction per D1). The root constructs the client against the local
/// endpoint and injects it; this type owns only the JSON-task framing,
/// fence-stripping, and decode-or-retry logic.
public struct LocalSmallModel: SmallModelService, Sendable {
    private let model: any ModelClient
    private let modelId: String
    private let maxOutputHint: Int

    public init(model: any ModelClient, modelId: String, maxOutputHint: Int = 512) {
        self.model = model; self.modelId = modelId; self.maxOutputHint = maxOutputHint
    }

    private static let jsonSystem =
        "You are a fast, precise classifier. Respond with ONLY a single JSON value that "
        + "matches the requested shape. No prose, no explanation, no markdown code fences."

    public func text(_ task: SmallTask) async throws -> String {
        let instructions = task.system ?? "You are a fast, helpful assistant. Be concise."
        var body = task.prompt
        if !task.input.isEmpty { body += "\n\n" + task.input }
        let prompt = Prompt(instructions: instructions, input: [.userText(body)])
        let settings = ModelSettings(model: modelId, threadId: "smallmodel", store: false)
        let stream = try await model.stream(prompt, settings)
        return try await Self.collect(stream)
    }

    public func json<T: Decodable & Sendable>(_ task: SmallTask, as type: T.Type) async throws -> T {
        var jsonTask = task
        if jsonTask.system == nil { jsonTask.system = Self.jsonSystem }
        var lastRaw = ""
        for attempt in 0..<2 {
            let t = attempt == 0 ? jsonTask
                : SmallTask(prompt: jsonTask.prompt
                            + "\n\nYour previous reply was not valid JSON. Reply with ONLY the JSON value.",
                            input: jsonTask.input, system: jsonTask.system)
            let raw = try await text(t).trimmingCharacters(in: .whitespacesAndNewlines)
            lastRaw = raw
            if raw.isEmpty { continue }
            // Try candidates in order of safety: the raw reply FIRST (so valid
            // JSON — even one whose string value contains backticks — is never
            // corrupted by fence-stripping), then a fenced block, then the
            // first {…}/[…] span (rescues prose-wrapped or truncated-fence JSON).
            for candidate in Self.jsonCandidates(raw) {
                if let data = candidate.data(using: .utf8),
                   let value = try? JSONDecoder().decode(T.self, from: data) {
                    return value
                }
            }
        }
        throw lastRaw.isEmpty ? SmallModelError.empty : SmallModelError.undecodable(lastRaw)
    }

    // MARK: - helpers

    /// Collect the final assistant text from a response stream. Drains the WHOLE
    /// stream (does NOT early-return on `.completed`, so a late `agentDone` is
    /// not missed): prefers the last non-empty `agentDone`, else accumulated
    /// deltas. Returns "" for an empty reply (the caller maps that to `.empty`).
    static func collect(_ stream: ResponseStream) async throws -> String {
        var deltas = ""
        var done: String?
        for try await ev in stream.events {
            switch ev {
            case .agentDelta(_, let d): deltas += d
            case .agentDone(_, let t): if !t.isEmpty { done = t }
            default: continue
            }
        }
        return done ?? deltas
    }

    /// Decode candidates, most-trustworthy first: (1) the raw reply, (2) the
    /// first ```-fenced block, (3) the first balanced-ish `{…}`/`[…]` span.
    static func jsonCandidates(_ s: String) -> [String] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = [t]
        if let f = firstFencedBlock(t), f != t { out.append(f) }
        if let b = bracedSpan(t), !out.contains(b) { out.append(b) }
        return out
    }

    /// Content of the first ```…``` fence (skipping an optional ```json language
    /// tag line); to end-of-string when the closing fence is missing.
    static func firstFencedBlock(_ t: String) -> String? {
        guard let open = t.range(of: "```") else { return nil }
        var start = open.upperBound
        if let nl = t[start...].firstIndex(of: "\n") { start = t.index(after: nl) }
        if let close = t.range(of: "```", range: start..<t.endIndex) {
            return String(t[start..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(t[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First `{` or `[` through the last `}` or `]` — rescues a JSON value
    /// embedded in prose or wrapped in a truncated fence.
    static func bracedSpan(_ t: String) -> String? {
        guard let openIdx = t.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let closeIdx = t.lastIndex(where: { $0 == "}" || $0 == "]" }),
              openIdx < closeIdx else { return nil }
        return String(t[openIdx...closeIdx])
    }

    /// Back-compat alias: the single best single-string extraction (fenced
    /// block if present, else the trimmed raw).
    static func stripFences(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstFencedBlock(t) ?? t
    }
}
