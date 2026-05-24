import Foundation
import Config
import MemoryScore

/// Process-global persona selection. The design doc holds personas as Config
/// profiles; this actor owns the active selection plus the lookup map. MCP
/// tools read/write through it so the `set_persona` tool persists between
/// calls in the same process.
public actor PersonaState {
    private var active: String
    private var personas: [String: Persona]

    public init(default name: String = "cto",
                personas: [String: Persona] = Persona.defaults) {
        self.personas = personas
        self.active = personas[name] != nil ? name : (personas.keys.sorted().first ?? "cto")
    }

    public func current() -> Persona {
        personas[active] ?? Persona.cto
    }

    public func list() -> [Persona] {
        personas.values.sorted { $0.name < $1.name }
    }

    public func setActive(_ name: String) -> Bool {
        guard personas[name] != nil else { return false }
        active = name
        return true
    }

    public func register(_ persona: Persona) {
        personas[persona.name] = persona
    }

    public func activeName() -> String { active }

    /// Load personas from `$CODEX_HOME/config.toml`. The expected shape is:
    ///
    ///     [memory.personas.cto]
    ///     weights = { embedding_novelty = 0.20, graph_novelty = 0.35,
    ///                 bridge_centrality = 0.35, information_gain = 0.10 }
    ///     entity_kind_bonuses = { org = 0.10, product = 0.10 }
    ///     time_decay_half_life_days = 30
    ///     pinned_topics = ["macos", "swift"]
    ///
    /// Missing keys fall back to the design doc's defaults. Personas missing
    /// from TOML stay at their compiled-in defaults so an empty config still
    /// boots cleanly.
    public static func load(codexHome: String,
                            defaultName: String = "cto") -> PersonaState {
        var merged = Persona.defaults
        let path = codexHome + "/config.toml"
        if let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8),
           let root = try? TOML.parse(text),
           let memory = root["memory"]?.objectValue,
           let personasTable = memory["personas"]?.objectValue {
            for (name, raw) in personasTable {
                guard case .object(let body) = raw else { continue }
                let base = merged[name] ?? Persona(name: name)
                merged[name] = applyOverrides(base, name: name, body: body)
            }
        }
        return PersonaState(default: defaultName, personas: merged)
    }

    private static func applyOverrides(_ base: Persona,
                                       name: String,
                                       body: [String: ConfigValue]) -> Persona {
        var out = base
        out = Persona(name: name,
                      weightEmbeddingNovelty: base.weightEmbeddingNovelty,
                      weightGraphNovelty: base.weightGraphNovelty,
                      weightBridgeCentrality: base.weightBridgeCentrality,
                      weightInformationGain: base.weightInformationGain,
                      entityKindBonuses: base.entityKindBonuses,
                      timeDecayHalfLifeDays: base.timeDecayHalfLifeDays,
                      pinnedTopics: base.pinnedTopics)
        if case .object(let w) = body["weights"] ?? .null {
            out.weightEmbeddingNovelty = doubleVal(w["embedding_novelty"])
                ?? out.weightEmbeddingNovelty
            out.weightGraphNovelty = doubleVal(w["graph_novelty"])
                ?? out.weightGraphNovelty
            out.weightBridgeCentrality = doubleVal(w["bridge_centrality"])
                ?? out.weightBridgeCentrality
            out.weightInformationGain = doubleVal(w["information_gain"])
                ?? out.weightInformationGain
        }
        if case .object(let b) = body["entity_kind_bonuses"] ?? .null {
            var bonuses = out.entityKindBonuses
            for (kind, raw) in b {
                if let v = doubleVal(raw) { bonuses[kind] = v }
            }
            out.entityKindBonuses = bonuses
        }
        if let half = doubleVal(body["time_decay_half_life_days"]) {
            out.timeDecayHalfLifeDays = half
        }
        if case .array(let arr) = body["pinned_topics"] ?? .null {
            out.pinnedTopics = arr.compactMap { $0.stringValue }
        }
        return out
    }

    private static func doubleVal(_ v: ConfigValue?) -> Double? {
        guard let v else { return nil }
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}
