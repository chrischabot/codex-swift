import Foundation

/// One model descriptor (subset of codex `models-manager::ModelInfo` relevant
/// to the portable harness).
public struct ModelEntry: Sendable, Equatable {
    public var slug: String
    public var displayName: String
    public var description: String
    public var contextWindow: Int
    public var maxContextWindow: Int
    public var effectiveContextPercent: Int   // codex default 95
    public var maxOutputTokens: Int
    public var isDefault: Bool
    public var hidden: Bool
    public var supportsTools: Bool
    public var tokenizerName: String           // for the optional BPE table

    public init(slug: String, displayName: String, description: String,
                contextWindow: Int = 272_000, maxContextWindow: Int = 272_000,
                effectiveContextPercent: Int = 95, maxOutputTokens: Int = 64_000,
                isDefault: Bool = false, hidden: Bool = false,
                supportsTools: Bool = true, tokenizerName: String = "o200k_base") {
        self.slug = slug
        self.displayName = displayName
        self.description = description
        self.contextWindow = contextWindow
        self.maxContextWindow = maxContextWindow
        self.effectiveContextPercent = effectiveContextPercent
        self.maxOutputTokens = maxOutputTokens
        self.isDefault = isDefault
        self.hidden = hidden
        self.supportsTools = supportsTools
        self.tokenizerName = tokenizerName
    }

    /// Upstream `ModelInfo::auto_compact_token_limit()`
    /// (protocol/src/openai_models.rs:322): the auto-compact TRIGGER limit is
    /// `(context_window * 9) / 10` — a hardcoded 90% window factor — NOT the
    /// `effective_context_window_percent` (95%, which is the separate
    /// display/effective-window gauge). Upstream additionally mins this with
    /// any configured `model_auto_compact_token_limit`; that config min is
    /// applied by `ModelCatalog.autoCompactLimit(for:configOverride:)`.
    public var autoCompactTokenLimit: Int {
        max(1, (contextWindow * 9) / 10)
    }
}

/// Read-only catalog. Resolution mirrors codex `models-manager::manager`
/// longest-matching-prefix selection (`model.starts_with(candidate.slug)` with
/// the longest slug winning); unknown slugs get the 272k fallback descriptor
/// (codex `model_info_from_slug`).
public struct ModelCatalog: Sendable {
    public let entries: [ModelEntry]

    public init(entries: [ModelEntry]) { self.entries = entries }

    /// The faithful default catalog (codex family + the gpt-4o-mini live-test
    /// model). Codex sources listings from the active remote catalog; these
    /// are the documented local-fallback shapes.
    public static let `default` = ModelCatalog(entries: [
        ModelEntry(slug: "gpt-5.5", displayName: "GPT-5.5",
                   description: "Default frontier model for complex coding, research, and real-world tasks.",
                   contextWindow: 272_000, maxContextWindow: 272_000,
                   isDefault: true),
        ModelEntry(slug: "gpt-5.2-codex", displayName: "GPT-5.2 Codex",
                   description: "Codex coding model.",
                   contextWindow: 272_000, maxContextWindow: 272_000),
        ModelEntry(slug: "gpt-5.1-codex", displayName: "GPT-5.1 Codex",
                   description: "Prior Codex coding model.",
                   contextWindow: 272_000, maxContextWindow: 272_000),
        ModelEntry(slug: "gpt-5.1", displayName: "GPT-5.1",
                   description: "GPT-5.1 general model.",
                   contextWindow: 272_000, maxContextWindow: 272_000),
        ModelEntry(slug: "gpt-5", displayName: "GPT-5",
                   description: "GPT-5 general model.",
                   contextWindow: 272_000, maxContextWindow: 272_000),
        ModelEntry(slug: "gpt-4o-mini", displayName: "GPT-4o mini",
                   description: "Fast, low-cost model (live-test default).",
                   contextWindow: 128_000, maxContextWindow: 128_000,
                   maxOutputTokens: 16_384, tokenizerName: "o200k_base"),
        ModelEntry(slug: "gpt-4o", displayName: "GPT-4o",
                   description: "GPT-4o general model.",
                   contextWindow: 128_000, maxContextWindow: 128_000,
                   maxOutputTokens: 16_384, tokenizerName: "o200k_base"),
        ModelEntry(slug: "o4-mini", displayName: "o4-mini",
                   description: "Reasoning model.",
                   contextWindow: 200_000, maxContextWindow: 200_000),
        // Realtime speech-to-speech voice models (`/v1/realtime`). 128k context,
        // 32k max output, knowledge cutoff 2024-09-30. Both slugs are present so
        // longest-prefix resolution picks `gpt-realtime-2` over `gpt-realtime`.
        // `hidden: true` keeps them resolvable (context window / tokenizer /
        // pricing) without surfacing them in the `model/list` coding picker —
        // the realtime model is selected server-side for the voice bridge, not
        // chosen for Responses-API coding turns.
        ModelEntry(slug: "gpt-realtime-2", displayName: "GPT Realtime 2",
                   description: "Most capable realtime voice model (speech-to-speech).",
                   contextWindow: 128_000, maxContextWindow: 128_000,
                   maxOutputTokens: 32_000, hidden: true, tokenizerName: "o200k_base"),
        ModelEntry(slug: "gpt-realtime", displayName: "GPT Realtime",
                   description: "Realtime speech-to-speech voice model.",
                   contextWindow: 128_000, maxContextWindow: 128_000,
                   maxOutputTokens: 32_000, hidden: true, tokenizerName: "o200k_base"),
    ])

    /// codex `model_info_from_slug` fallback for unknown slugs.
    public static func fallback(_ slug: String) -> ModelEntry {
        ModelEntry(slug: slug, displayName: slug,
                   description: "Unknown model; using fallback metadata.",
                   contextWindow: 272_000, maxContextWindow: 272_000)
    }

    /// Longest-prefix slug resolution (codex manager.rs).
    public func resolve(_ slug: String) -> ModelEntry {
        let matches = entries.filter { slug.hasPrefix($0.slug) || slug == $0.slug }
        if let best = matches.max(by: { $0.slug.count < $1.slug.count }) {
            return best
        }
        if let exact = entries.first(where: { $0.slug == slug }) { return exact }
        return Self.fallback(slug)
    }

    /// Upstream `ModelInfo::auto_compact_token_limit()`
    /// (protocol/src/openai_models.rs:322): the auto-compaction TRIGGER limit is
    /// the min of any user-configured `model_auto_compact_token_limit`
    /// (`configOverride`) and the model's 90%-context-window value. When
    /// `configOverride` is nil the window-derived value is used verbatim:
    /// `config_limit.map_or(context_limit, |l| min(l, context_limit))`.
    public func autoCompactLimit(for slug: String, configOverride: Int? = nil) -> Int {
        let contextLimit = resolve(slug).autoCompactTokenLimit
        guard let override = configOverride else { return contextLimit }
        return Swift.min(override, contextLimit)
    }

    public func contextWindow(for slug: String) -> Int {
        resolve(slug).contextWindow
    }

    public func defaultEntry() -> ModelEntry {
        entries.first(where: { $0.isDefault }) ?? entries.first
            ?? Self.fallback("gpt-5.5")
    }

    public func listed() -> [ModelEntry] {
        entries.filter { !$0.hidden }
            .sorted { $0.isDefault && !$1.isDefault }
    }
}