import Foundation

/// Vendor of `codex-rs/models-manager/models.json` — the same data file
/// upstream ships and consults via `get_model_instructions(personality)`
/// (`codex-rs/protocol/src/openai_models.rs:341`). Each entry carries
/// `base_instructions` (fallback prose), `model_messages.instructions_template`
/// (the `{{ personality }}`-templated prompt the Responses API expects in
/// `instructions`), and `model_messages.instructions_variables` (the
/// personality fragment to substitute).
///
/// Codex-rs can refresh this file from the remote `/models` endpoint;
/// codex-swift currently relies on the bundled snapshot. Refresh by
/// re-copying `codex-rs/models-manager/models.json` into
/// `Sources/Prompts/Resources/models.json`.
public enum ModelsCatalog {

    /// One entry per model slug. Decodes only the fields we actually consume
    /// from the upstream JSON — the rest is forward-compatible.
    public struct Entry: Sendable {
        public let slug: String
        public let baseInstructions: String?
        public let instructionsTemplate: String?
        public let instructionsVariables: [String: String]
        /// Mirrors `supports_parallel_tool_calls` in `models.json`. When true,
        /// the Responses request should set `parallel_tool_calls: true` so the
        /// model may emit several `function_call` items per response and the
        /// agent loop dispatches them concurrently — collapsing what would
        /// otherwise be N serial round-trips into one. Defaults to false for
        /// safety on unknown models.
        public let supportsParallelToolCalls: Bool
        /// Mirrors `shell_type` in `models.json` (upstream
        /// `ConfigShellToolType`). Selects which shell-tool family the model is
        /// offered; consumed by `DefaultTools.register(shellType:)`. Stored as
        /// the raw serde string so the Tools layer can map it without taking a
        /// Prompts→Tools dependency. Defaults to `"shell_command"` (the value
        /// every shipped model declares) for unknown/missing entries.
        public let shellType: String
        /// Mirrors `apply_patch_tool_type` in `models.json` (upstream
        /// `protocol/src/openai_models.rs::ApplyPatchToolType`). `"freeform"`
        /// means the model accepts the custom-grammar (`type:"custom"`)
        /// apply_patch tool; `nil` (the default for every non-gpt-5 model,
        /// e.g. `gpt-4o*`) means the model does NOT support the custom tool
        /// type — upstream then omits the freeform apply_patch tool entirely
        /// rather than send a `type:"custom"` the Responses API rejects with
        /// `400 Invalid value: 'custom'`. The Swift request builder consults
        /// this to downgrade the freeform tool to a plain JSON `function` tool
        /// for such models (keeping apply_patch usable) instead of emitting an
        /// unsupported `type:"custom"`.
        public let applyPatchToolType: String?
        /// Mirrors `supports_reasoning_summaries` in `models.json` (upstream
        /// `ModelInfo`). When true, the Responses request emits a `reasoning`
        /// object (and `include: ["reasoning.encrypted_content"]`) even when
        /// the caller specifies no effort; when false, reasoning is suppressed
        /// entirely. Defaults to false for unknown models.
        public let supportsReasoningSummaries: Bool
        /// Mirrors `default_reasoning_level` — the effort used when the caller
        /// supplies none and the model supports reasoning.
        public let defaultReasoningLevel: String?
        /// Mirrors `default_reasoning_summary`.
        public let defaultReasoningSummary: String?
        /// Mirrors `support_verbosity`. When false, `text.verbosity` is dropped
        /// from the request even if configured. Defaults to false.
        public let supportVerbosity: Bool
        /// Mirrors `input_modalities` in `models.json` (upstream
        /// `ModelInfo::input_modalities`). The set of input modalities the
        /// model accepts (e.g. `["text", "image"]`). Used to decide whether
        /// MCP `image` content blocks are passed through to the model or
        /// replaced with the omission placeholder
        /// (`mcp_tool_call.rs::sanitize_mcp_tool_result_for_model`). Empty when
        /// the catalog entry omits the field.
        public let inputModalities: [String]
        /// Mirrors `output_modalities` in `models.json` (upstream
        /// `ModelInfo::output_modalities`). The set of modalities the model can
        /// emit (e.g. `["text", "audio"]` for the realtime voice models).
        /// Empty when the catalog entry omits the field.
        public let outputModalities: [String]
        /// Mirrors the `realtime` flag in `models.json`. True for the
        /// speech-to-speech voice models served over `/v1/realtime`
        /// (`gpt-realtime`, `gpt-realtime-2`). These are NOT used by the
        /// Responses-API agent turn loop; they drive the realtime voice bridge
        /// (`thread/realtime/*` → OpenAI Realtime WebSocket).
        public let realtime: Bool
        /// Mirrors the `id`s of the `service_tiers` array in `models.json`
        /// (upstream `ModelInfo::service_tiers`). The set of service-tier ids
        /// the model advertises (e.g. `["priority"]`). Upstream gates the
        /// requested `service_tier` against this list
        /// (`ModelInfo::supports_service_tier`, `openai_models.rs:491-495`),
        /// dropping a tier the model does not advertise before serialization.
        /// Empty when the catalog entry omits the field or declares no tiers.
        public let serviceTiers: [String]

        /// Whether this model advertises `serviceTier`. Mirrors upstream
        /// `ModelInfo::supports_service_tier` (`openai_models.rs:491-495`):
        /// the requested tier is supported iff some entry's `id` matches.
        public func supportsServiceTier(_ serviceTier: String) -> Bool {
            serviceTiers.contains(serviceTier)
        }

        /// Whether this model accepts image input (upstream
        /// `InputModality::Image`). True when `input_modalities` contains
        /// `"image"`.
        public var supportsImageInput: Bool {
            inputModalities.contains("image")
        }

        /// Whether this model accepts audio input. True when `input_modalities`
        /// contains `"audio"` (the realtime voice models).
        public var supportsAudioInput: Bool {
            inputModalities.contains("audio")
        }

        /// Whether this model can emit audio output. True when
        /// `output_modalities` contains `"audio"` (the realtime voice models).
        public var supportsAudioOutput: Bool {
            outputModalities.contains("audio")
        }

        /// Resolve `instructions` for this model with the given personality
        /// kebab/lowercase identifier (`"default"`, `"pragmatic"`, `"friendly"`).
        /// Mirrors `openai_models.rs::get_model_instructions`:
        ///
        /// - If `instructions_template` is present, return the template with
        ///   `{{ personality }}` replaced by
        ///   `instructions_variables["personality_<id>"]` (falling back to
        ///   `personality_default`, then empty).
        /// - Otherwise return `base_instructions`.
        public func instructions(personality: String) -> String {
            let id = personality.lowercased()
            let key = "personality_\(id)"
            let fallbackKey = "personality_default"
            // Upstream `get_personality_message`: `Personality::None => String::new()`.
            // `models.json` ships no `personality_none` fragment, so an explicit
            // `none` must resolve to the empty string — NOT fall back to
            // `personality_default` (which would inject the pragmatic prose).
            let personalityText: String =
                id == "none"
                ? (instructionsVariables[key] ?? "")
                : (instructionsVariables[key]
                   ?? instructionsVariables[fallbackKey]
                   ?? "")
            if let template = instructionsTemplate {
                return template.replacingOccurrences(of: "{{ personality }}",
                                                     with: personalityText)
            }
            return baseInstructions ?? ""
        }
    }

    private struct RawCatalog: Decodable {
        let models: [RawEntry]
    }

    private struct RawEntry: Decodable {
        let slug: String
        let baseInstructions: String?
        let modelMessages: RawModelMessages?
        let supportsParallelToolCalls: Bool?
        let shellType: String?
        let applyPatchToolType: String?
        let supportsReasoningSummaries: Bool?
        let defaultReasoningLevel: String?
        let defaultReasoningSummary: String?
        let supportVerbosity: Bool?
        let inputModalities: [String]?
        let outputModalities: [String]?
        let realtime: Bool?
        let serviceTiers: [RawServiceTier]?

        enum CodingKeys: String, CodingKey {
            case slug
            case baseInstructions = "base_instructions"
            case modelMessages = "model_messages"
            case supportsParallelToolCalls = "supports_parallel_tool_calls"
            case shellType = "shell_type"
            case applyPatchToolType = "apply_patch_tool_type"
            case supportsReasoningSummaries = "supports_reasoning_summaries"
            case defaultReasoningLevel = "default_reasoning_level"
            case defaultReasoningSummary = "default_reasoning_summary"
            case supportVerbosity = "support_verbosity"
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
            case realtime
            case serviceTiers = "service_tiers"
        }
    }

    private struct RawServiceTier: Decodable {
        let id: String
    }

    private struct RawModelMessages: Decodable {
        let instructionsTemplate: String?
        let instructionsVariables: [String: String]?

        enum CodingKeys: String, CodingKey {
            case instructionsTemplate = "instructions_template"
            case instructionsVariables = "instructions_variables"
        }
    }

    /// Loaded lazily, once per process. Keyed by slug.
    public static let entries: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode(RawCatalog.self, from: data) else {
            return [:]
        }
        var out: [String: Entry] = [:]
        for r in raw.models {
            // instructions_variables values can be strings, null, or empty.
            // Upstream stores empty fragments for `personality_default`.
            let vars = r.modelMessages?.instructionsVariables ?? [:]
            out[r.slug] = Entry(slug: r.slug,
                                baseInstructions: r.baseInstructions,
                                instructionsTemplate: r.modelMessages?.instructionsTemplate,
                                instructionsVariables: vars,
                                supportsParallelToolCalls: r.supportsParallelToolCalls ?? false,
                                shellType: r.shellType ?? "shell_command",
                                applyPatchToolType: r.applyPatchToolType,
                                supportsReasoningSummaries: r.supportsReasoningSummaries ?? false,
                                defaultReasoningLevel: r.defaultReasoningLevel,
                                defaultReasoningSummary: r.defaultReasoningSummary,
                                supportVerbosity: r.supportVerbosity ?? false,
                                inputModalities: r.inputModalities ?? [],
                                outputModalities: r.outputModalities ?? [],
                                realtime: r.realtime ?? false,
                                serviceTiers: (r.serviceTiers ?? []).map { $0.id })
        }
        return out
    }()

    /// Look up `slug` in the bundled catalog. Returns nil for unknown slugs;
    /// callers should fall through to `Templates.defaultBaseInstructions`.
    public static func entry(for slug: String) -> Entry? {
        entries[slug]
    }

    /// Whether `slug` accepts the custom-grammar (`type:"custom"`) freeform
    /// apply_patch tool. Mirrors upstream's `apply_patch_tool_type.is_some()`
    /// gate (only the gpt-5 family declares `"freeform"`). Unknown / non-gpt-5
    /// models (e.g. `gpt-4o-mini`) return false, so the request builder must
    /// NOT send them a `type:"custom"` tool (the Responses API rejects it with
    /// `400 Invalid value: 'custom'`).
    public static func supportsFreeformTools(_ slug: String) -> Bool {
        entries[slug]?.applyPatchToolType != nil
    }

    /// Whether `slug` is a realtime speech-to-speech voice model (served over
    /// the OpenAI `/v1/realtime` WebSocket rather than the Responses API).
    /// Catalog-driven via the `realtime` flag; falls back to the `gpt-realtime`
    /// slug family so unknown dated snapshots (`gpt-realtime-2-2025-…`) still
    /// resolve correctly.
    public static func isRealtime(_ slug: String) -> Bool {
        if let entry = entries[slug] { return entry.realtime }
        return slug.lowercased().hasPrefix("gpt-realtime")
    }
}
