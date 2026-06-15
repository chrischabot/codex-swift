import Foundation

/// Options for `Mem0Engine.add`. Port of the Rust `AddOptions`.
public struct AddOptions: Sendable {
    public var userID: String?
    public var agentID: String?
    public var runID: String?
    public var metadata: JSONObject?
    public var infer: Bool?
    public var memoryType: String?
    public var prompt: String?
    public init(userID: String? = nil, agentID: String? = nil, runID: String? = nil,
                metadata: JSONObject? = nil, infer: Bool? = nil,
                memoryType: String? = nil, prompt: String? = nil) {
        self.userID = userID; self.agentID = agentID; self.runID = runID
        self.metadata = metadata; self.infer = infer
        self.memoryType = memoryType; self.prompt = prompt
    }
}

/// Options for `Mem0Engine.search`. Port of the Rust `SearchOptions`.
public struct SearchOptions: Sendable {
    public var topK: Int
    public var threshold: Double
    public init(topK: Int = 20, threshold: Double = 0.1) {
        self.topK = topK; self.threshold = threshold
    }
}

/// The mem0 orchestrator. Holds injected providers + the history store and
/// implements the full mem0 surface. Port of `mem0-rs/.../memory.rs`.
public struct Mem0Engine: Sendable {
    static let proceduralMemoryType = "procedural_memory"
    static let promotedKeys = ["user_id", "agent_id", "run_id", "actor_id", "role"]

    public let config: Mem0Config
    let embedder: any Mem0Embedder
    let llm: any Mem0LLM
    let vectorStore: any Mem0VectorStore
    let historyStore: any Mem0HistoryStore
    let entityStore: (any Mem0VectorStore)?
    let customInstructions: String?

    public init(config: Mem0Config,
                embedder: any Mem0Embedder,
                llm: any Mem0LLM,
                vectorStore: any Mem0VectorStore,
                historyStore: any Mem0HistoryStore,
                entityStore: (any Mem0VectorStore)? = nil) {
        self.config = config
        self.embedder = embedder
        self.llm = llm
        self.vectorStore = vectorStore
        self.historyStore = historyStore
        self.entityStore = entityStore
        self.customInstructions = config.customInstructions
    }

    /// Return a copy with an entity store attached (best-effort linking/boosts).
    public func withEntityStore(_ store: any Mem0VectorStore) -> Mem0Engine {
        Mem0Engine(config: config, embedder: embedder, llm: llm,
                   vectorStore: vectorStore, historyStore: historyStore,
                   entityStore: store)
    }

    // MARK: - add

    public func add(_ messages: MessagesInput, _ opts: AddOptions) async throws -> [AddResult] {
        let (processedMetadata, effectiveFilters) = try Mem0Filters.buildFiltersAndMetadata(
            userID: opts.userID, agentID: opts.agentID, runID: opts.runID,
            actorID: nil, inputMetadata: opts.metadata, inputFilters: nil)

        if let mt = opts.memoryType, mt != Self.proceduralMemoryType {
            throw Mem0Error.validationCode(
                "VALIDATION_002",
                "Invalid 'memory_type'. Please pass \(Self.proceduralMemoryType) to create procedural memories.",
                "Use '\(Self.proceduralMemoryType)' to create procedural memories.")
        }

        let msgs = messages.intoMessages()

        if opts.memoryType == Self.proceduralMemoryType {
            return try await createProceduralMemory(msgs, processedMetadata, opts.prompt)
        }

        let infer = opts.infer ?? true
        if !infer {
            return try await addToVectorStoreRaw(msgs, processedMetadata)
        }
        return try await addToVectorStoreInfer(msgs, processedMetadata, effectiveFilters, opts.prompt)
    }

    /// Non-inferred add: store each non-system message verbatim.
    func addToVectorStoreRaw(_ messages: [Message], _ metadata: JSONObject) async throws -> [AddResult] {
        var returned: [AddResult] = []
        for message in messages where message.role != "system" {
            var perMsg = metadata
            perMsg["role"] = .string(message.role)
            if let name = message.name { perMsg["actor_id"] = .string(name) }
            let memID = try await createMemory(data: message.content, precomputed: nil, metadata: perMsg)
            returned.append(AddResult(id: memID, memory: message.content, event: "ADD",
                                      actorID: message.name, role: message.role))
        }
        return returned
    }

    /// Inferred additive-extraction pipeline. Port of `add_to_vector_store_infer`.
    func addToVectorStoreInfer(_ messages: [Message], _ metadata: JSONObject,
                               _ filters: JSONObject, _ prompt: String?) async throws -> [AddResult] {
        // Phase 0: context.
        let sessionScope = Mem0Filters.buildSessionScope(filters)
        let last = (try? await historyStore.getLastMessages(sessionScope, limit: 10)) ?? []
        let lastK: [(String, String)] = last.map { ($0.role ?? "", $0.content ?? "") }
        let parsedMessages = Mem0Text.parseMessages(messages)

        // Phase 1: existing-memory retrieval.
        let searchFilters = Mem0Filters.sessionFilters(filters)
        let queryEmbedding = try await embedder.embed(parsedMessages, .search)
        let existing = (try? await vectorStore.search(parsedMessages, queryEmbedding, topK: 10, filters: searchFilters)) ?? []
        var existingMemories: [JSONValue] = []
        for (idx, mem) in existing.enumerated() {
            let text = mem.payload["data"]?.stringValue ?? ""
            existingMemories.append(.object(["id": .string(String(idx)), "text": .string(text)]))
        }

        // Phase 2: LLM extraction.
        let isAgentScoped = filters["agent_id"] != nil && filters["user_id"] == nil
        let systemPrompt = isAgentScoped
            ? Mem0PromptConstants.additiveExtractionPrompt + Mem0PromptConstants.agentContextSuffix
            : Mem0PromptConstants.additiveExtractionPrompt
        let customInstr = prompt ?? customInstructions
        var args = Mem0Prompts.AdditivePromptArgs()
        args.existingMemories = existingMemories
        args.newMessages = parsedMessages
        args.lastKMessages = lastK
        args.customInstructions = customInstr
        let userPrompt = Mem0Prompts.generateAdditiveExtractionPrompt(args)

        let llmMessages = [Message.system(systemPrompt), Message.user(userPrompt)]
        let opts = GenerateOptions(responseFormatJSON: true)
        let response: String
        do {
            response = try await llm.generate(llmMessages, opts)
        } catch {
            return []
        }

        let cleaned = Mem0Text.removeCodeBlocks(response)
        var extracted = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : Self.parseMemoryArray(cleaned)
        if extracted.isEmpty {
            try? await historyStore.saveMessages(messages, scope: sessionScope)
            return []
        }

        // Phase 3: batch embed.
        let memTexts: [String] = extracted.compactMap {
            guard let t = $0.objectValue?["text"]?.stringValue, !t.isEmpty else { return nil }
            guard !Mem0SecretScanner.containsSecret(t) else { return nil }
            return t
        }
        var embedMap: [String: [Float]] = [:]
        if let vs = try? await embedder.embedBatch(memTexts, .add), vs.count == memTexts.count {
            for (t, v) in zip(memTexts, vs) { embedMap[t] = v }
        } else {
            for t in memTexts {
                if let v = try? await embedder.embed(t, .add) { embedMap[t] = v }
            }
        }

        // Phase 3.5: reconciliation (gbrain.md Wave 0.4) — OFF by default. When on,
        // split extracted facts into ADD (fall through to Phase 4–6) vs near-dup-skip
        // vs an LLM update pass over mid-band matches (UPDATE/DELETE/ADD/NONE). This
        // closes the documented ADD-only gap so a corrected fact supersedes the stale
        // one instead of accumulating a contradictory duplicate.
        var reconcileResults: [AddResult] = []
        if config.reconcileOnAdd {
            let outcome = await reconcileExtracted(extracted, embedMap: embedMap,
                                                   searchFilters: searchFilters)
            extracted = outcome.addFacts
            reconcileResults = outcome.results
            if extracted.isEmpty {
                // Only updates/deletes/skips happened — still persist the conversation.
                try? await historyStore.saveMessages(messages, scope: sessionScope)
                return reconcileResults
            }
        }

        // Phases 4–5: build records with hash dedup.
        var existingHashes = Set<String>()
        for mem in existing {
            if let h = mem.payload["hash"]?.stringValue { existingHashes.insert(h) }
        }

        var records: [(id: String, text: String, vector: [Float], payload: JSONObject)] = []
        var seenHashes = Set<String>()
        for mem in extracted {
            guard let text = mem.objectValue?["text"]?.stringValue, !text.isEmpty else { continue }
            guard !Mem0SecretScanner.containsSecret(text) else { continue }
            guard let embedding = embedMap[text] else { continue }
            let memHash = md5Hex(text)
            if existingHashes.contains(memHash) || seenHashes.contains(memHash) { continue }
            seenHashes.insert(memHash)

            var meta = metadata
            meta["data"] = .string(text)
            meta["text_lemmatized"] = .string(Mem0NLP.lemmatizeForBM25(text))
            meta["hash"] = .string(memHash)
            let created = nowUTCRFC3339()
            if meta["created_at"] == nil { meta["created_at"] = .string(created) }
            let createdAt = meta["created_at"]?.stringValue ?? created
            meta["updated_at"] = .string(createdAt)
            if let att = mem.objectValue?["attributed_to"]?.stringValue {
                meta["attributed_to"] = .string(att)
            }
            records.append((UUID().uuidString, text, embedding, meta))
        }

        if records.isEmpty {
            try? await historyStore.saveMessages(messages, scope: sessionScope)
            return []
        }

        // Phase 6: persist (batch, with per-item fallback).
        let vrecords = records.map { VectorRecord(id: $0.id, vector: $0.vector, payload: $0.payload) }
        var persisted: [(id: String, text: String, vector: [Float], payload: JSONObject)] = []
        do {
            try await vectorStore.insert(vrecords)
            persisted = records
        } catch {
            for r in records {
                if (try? await vectorStore.insert([VectorRecord(id: r.id, vector: r.vector, payload: r.payload)])) != nil {
                    persisted.append(r)
                }
            }
        }
        if persisted.isEmpty {
            try? await historyStore.saveMessages(messages, scope: sessionScope)
            return []
        }

        // History (batch, per-item fallback).
        let hrecords: [NewHistory] = persisted.map { r in
            let createdAt = r.payload["created_at"]?.stringValue
            return NewHistory(memoryID: r.id, oldMemory: nil, newMemory: r.text, event: "ADD",
                              createdAt: createdAt, updatedAt: createdAt, isDeleted: 0,
                              actorID: nil, role: nil,
                              userID: r.payload["user_id"]?.stringValue,
                              agentID: r.payload["agent_id"]?.stringValue,
                              runID: r.payload["run_id"]?.stringValue)
        }
        if (try? await historyStore.batchAddHistory(hrecords)) == nil {
            for h in hrecords {
                try? await historyStore.addHistory(memoryID: h.memoryID, oldMemory: nil,
                                                   newMemory: h.newMemory, event: "ADD",
                                                   createdAt: h.createdAt, updatedAt: h.updatedAt,
                                                   isDeleted: 0, actorID: nil, role: nil,
                                                   userID: h.userID, agentID: h.agentID,
                                                   runID: h.runID)
            }
        }

        // Phase 7: best-effort entity linking.
        await linkEntities(persisted, searchFilters)

        // Phase 8: persist messages + return (reconciliation UPDATE/DELETE results first).
        try? await historyStore.saveMessages(messages, scope: sessionScope)
        return reconcileResults + persisted.map { AddResult(id: $0.id, memory: $0.text, event: "ADD") }
    }

    private struct ReconcileOutcome {
        var addFacts: [JSONValue]   // facts that should still flow through Phase 4–6 as ADDs
        var results: [AddResult]    // UPDATE/DELETE results already applied
    }

    /// Two-tier reconciliation of newly-extracted facts against existing memories
    /// (gbrain.md Wave 0.4). Per fact: a cosine fast-path skips near-duplicates
    /// (≥ dupCosineThreshold) with NO LLM; a mid-band match (≥ reconcileCosineThreshold)
    /// is collected for ONE batched LLM update pass (the dormant
    /// `getUpdateMemoryMessages`) that emits UPDATE/DELETE/ADD/NONE; everything else
    /// is a clear ADD. UPDATE/DELETE are applied via the existing primitives. On any
    /// LLM failure we fall back to ADD-all (never silently lose a fact).
    private func reconcileExtracted(_ extracted: [JSONValue], embedMap: [String: [Float]],
                                    searchFilters: JSONObject) async -> ReconcileOutcome {
        let dupCos = config.dupCosineThreshold
        let lowCos = config.reconcileCosineThreshold
        var adds: [JSONValue] = []
        var results: [AddResult] = []
        var seenHashes = Set<String>()

        for mem in extracted {
            guard let text = mem.objectValue?["text"]?.stringValue, !text.isEmpty,
                  !Mem0SecretScanner.containsSecret(text), let emb = embedMap[text] else { continue }
            let h = md5Hex(text)
            if seenHashes.contains(h) { continue }
            seenHashes.insert(h)

            let top = (try? await vectorStore.search(text, emb, topK: 1, filters: searchFilters))?.first
            let cos = top?.score ?? 0
            let matchText = top?.payload["data"]?.stringValue ?? ""

            // Near-duplicate fast-path: skip with NO write/LLM ONLY when the new fact
            // is also (normalized) textually identical — a high cosine ALONE can be a
            // CORRECTION (number swap) or NEGATION, which must NOT be silently dropped.
            if top != nil, cos >= dupCos, Self.normalizedEqual(text, matchText) { continue }

            guard let top, cos >= lowCos else {
                adds.append(mem)   // clearly new (below the reconcile band, or no match)
                continue
            }

            // Reconcile THIS fact against its SINGLE match. Per-fact scope means an
            // injected fact can only ever touch its OWN matched memory — never
            // mass-delete others — and an omitted/aborted decision re-ADDs (no loss).
            switch await reconcileOne(newText: text, newEmb: emb, matchID: top.id, matchText: matchText) {
            case .addNew: adds.append(.object(["text": .string(text)]))
            case .skip:   break
            case .applied(let r): results.append(r)
            }
        }
        return ReconcileOutcome(addFacts: adds, results: results)
    }

    private enum OneOutcome { case addNew, skip, applied(AddResult) }

    /// Reconcile ONE new fact against ONE existing match via the LLM update pass.
    /// The LLM sees ONLY this single (fact, match) pair, so it can only ever
    /// UPDATE/DELETE `matchID` — never another memory (no mass-delete). An omitted
    /// decision or ANY LLM failure re-ADDs the fact (never silently lost). Both
    /// texts are sanitized before they enter the prompt.
    private func reconcileOne(newText: String, newEmb: [Float],
                              matchID: String, matchText: String) async -> OneOutcome {
        let retrievedOld: [JSONValue] = [.object([
            "id": .string(matchID), "text": .string(Self.sanitizeForPrompt(matchText))])]
        let newFacts: [JSONValue] = [.object(["text": .string(Self.sanitizeForPrompt(newText))])]
        let prompt = Mem0Prompts.getUpdateMemoryMessages(retrievedOldMemory: retrievedOld, responseContent: newFacts)
        guard let resp = try? await llm.generate([.user(prompt)], GenerateOptions(responseFormatJSON: true)) else {
            return .addNew   // LLM failure → never lose the fact
        }
        for e in Self.parseMemoryArray(Mem0Text.removeCodeBlocks(resp)) {
            guard let obj = e.objectValue else { continue }
            let id = obj["id"]?.stringValue ?? ""
            let evText = obj["text"]?.stringValue ?? ""
            switch (obj["event"]?.stringValue ?? "").uppercased() {
            case "UPDATE" where id == matchID:
                guard !evText.isEmpty, !Mem0SecretScanner.containsSecret(evText) else { return .addNew }
                let emb: [Float]?
                if evText == newText { emb = newEmb } else { emb = try? await embedder.embed(evText, .update) }
                // metadata: nil → updateMemory preserves the EXISTING record's scope +
                // created_at (it re-derives user/agent/run/actor/role from that row).
                if (try? await updateMemory(matchID, data: evText, precomputed: emb, metadata: nil)) != nil {
                    return .applied(AddResult(id: matchID, memory: evText, event: "UPDATE"))
                }
                return .addNew
            case "DELETE" where id == matchID:
                if (try? await deleteMemory(matchID, existing: nil)) != nil {
                    return .applied(AddResult(id: matchID, memory: matchText, event: "DELETE"))
                }
                return .skip
            case "ADD":
                return .addNew
            case "NONE", "":
                return .skip   // explicit redundancy (≥ reconcile band) → drop
            default:
                continue
            }
        }
        return .addNew   // no applicable decision (LLM omission) → never lose the fact
    }

    /// Normalized text equality (lowercase + whitespace-collapsed) — distinguishes a
    /// true duplicate from a high-cosine contradiction in the dedup fast-path.
    static func normalizedEqual(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return norm(a) == norm(b)
    }

    /// Neutralize injection vectors in UNTRUSTED fact/memory text before it enters
    /// the reconcile update prompt. Mem0Core can't import MemoryInfer's
    /// `ContextSanitizer`, so this inlines its core: defang markdown code fences (so
    /// an injected ```{"memory":…}``` block isn't read as structure) and
    /// bracket-neutralize role/envelope breakout tags. Structural JSON injection is
    /// further contained because `serializeMemories` JSON-encodes the text as a
    /// string value.
    static func sanitizeForPrompt(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "```", with: "'''")
        // Neutralize ANY tag-like token `<…>` by bracket-swapping (`<`→`[`, `>`→`]`),
        // not just a fixed allowlist — robust to whitespace (`< memory >`), case
        // (`<MeMoRy>`), and tags off the list (`<prompt>`, `<context>`,
        // `<|im_start|>`). "Tag-like" = optional `/`, then a CONTIGUOUS word/marker
        // name (letters, digits, `| _ : -`), optionally space-padded, closed by `>`.
        // Requiring a contiguous name avoids mangling benign prose like `a < b and c > d`.
        if let re = try? NSRegularExpression(pattern: #"<\s*/?\s*[A-Za-z|][A-Za-z0-9|_:-]*\s*/?>"#) {
            let ns = s as NSString
            let mutable = NSMutableString(string: s)
            // Apply in reverse so earlier match ranges stay valid as we mutate.
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let tok = ns.substring(with: m.range)
                let neutral = tok.replacingOccurrences(of: "<", with: "[").replacingOccurrences(of: ">", with: "]")
                mutable.replaceCharacters(in: m.range, with: neutral)
            }
            s = mutable as String
        }
        return s
    }

    /// Procedural memory. Port of `create_procedural_memory`.
    func createProceduralMemory(_ messages: [Message], _ metadata: JSONObject,
                                _ prompt: String?) async throws -> [AddResult] {
        var parsed: [Message] = []
        parsed.append(.system(prompt ?? Mem0PromptConstants.proceduralMemorySystemPrompt))
        parsed.append(contentsOf: messages)
        parsed.append(.user("Create procedural memory of the above conversation."))

        let response = try await llm.generate(parsed, GenerateOptions())
        let procedural = Mem0Text.removeCodeBlocks(response)

        var meta = metadata
        meta["memory_type"] = .string(Self.proceduralMemoryType)
        let embedding = try await embedder.embed(procedural, .add)
        let id = try await createMemory(data: procedural, precomputed: embedding, metadata: meta)
        return [AddResult(id: id, memory: procedural, event: "ADD")]
    }

    /// Create a single memory + ADD history. Port of `create_memory`.
    func createMemory(data: String, precomputed: [Float]?, metadata: JSONObject) async throws -> String {
        let embeddings: [Float]
        if let p = precomputed { embeddings = p } else { embeddings = try await embedder.embed(data, .add) }
        let memoryID = UUID().uuidString
        var meta = metadata
        meta["data"] = .string(data)
        meta["hash"] = .string(md5Hex(data))
        if meta["created_at"] == nil { meta["created_at"] = .string(nowUTCRFC3339()) }
        let createdAt = meta["created_at"]?.stringValue ?? ""
        meta["updated_at"] = .string(createdAt)
        meta["text_lemmatized"] = .string(Mem0NLP.lemmatizeForBM25(data))

        let actorID = meta["actor_id"]?.stringValue
        let role = meta["role"]?.stringValue

        try await vectorStore.insert([VectorRecord(id: memoryID, vector: embeddings, payload: meta)])
        try await historyStore.addHistory(memoryID: memoryID, oldMemory: nil, newMemory: data,
                                          event: "ADD", createdAt: createdAt, updatedAt: createdAt,
                                          isDeleted: 0, actorID: actorID, role: role,
                                          userID: meta["user_id"]?.stringValue,
                                          agentID: meta["agent_id"]?.stringValue,
                                          runID: meta["run_id"]?.stringValue)
        return memoryID
    }

    // MARK: - reads

    public func get(_ memoryID: String) async throws -> JSONValue? {
        guard let memory = try await vectorStore.get(memoryID) else { return nil }
        return Self.formatMemoryItem(memory, excludeScore: false)
    }

    public func getAll(_ filters: JSONObject, topK: Int?) async throws -> JSONValue {
        if !["user_id", "agent_id", "run_id"].contains(where: { filters[$0] != nil }) {
            throw Mem0Error.validationCode("VALIDATION_001",
                                           "filters must contain at least one of: user_id, agent_id, run_id.",
                                           "Example: filters={\"user_id\": \"u1\"}")
        }
        let hits = try await vectorStore.list(filters, limit: topK)
        let results = hits.map { Self.formatMemoryItem($0, excludeScore: true) }
        return .object(["results": .array(results)])
    }

    // MARK: - search

    public func search(_ query: String, _ filters: JSONObject, _ options: SearchOptions) async throws -> JSONValue {
        try Mem0Filters.validateSearchParams(threshold: options.threshold, topK: options.topK)

        var effective = filters
        let sessionScope = Mem0Filters.sessionFilters(effective)
        if sessionScope.isEmpty {
            throw Mem0Error.validationCode("VALIDATION_001",
                                           "filters must contain at least one of: user_id, agent_id, run_id.",
                                           "Example: filters={\"user_id\": \"u1\"}")
        }

        if Mem0Filters.hasAdvancedOperators(effective) {
            let processed = try Mem0Filters.processMetadataFilters(effective)
            for lk in ["AND", "OR", "NOT"] { effective[lk] = nil }
            for fk in Array(effective.keys) {
                if !["AND", "OR", "NOT", "user_id", "agent_id", "run_id"].contains(fk),
                   effective[fk]?.objectValue != nil {
                    effective[fk] = nil
                }
            }
            for (k, v) in processed { effective[k] = v }
            for (k, v) in sessionScope { effective[k] = v }
        }

        let results = try await searchVectorStore(query, effective, limit: options.topK, threshold: options.threshold)
        return .object(["results": .array(results)])
    }

    func searchVectorStore(_ query: String, _ filters: JSONObject, limit: Int, threshold: Double) async throws -> [JSONValue] {
        let queryLemmatized = Mem0NLP.lemmatizeForBM25(query)
        let queryEntities = (entityStore != nil) ? Mem0NLP.extractEntities(query) : []

        let embeddings = try await embedder.embed(query, .search)
        let boundedLimit = Swift.min(Swift.max(limit, 1), 1_000)
        let internalLimit = Swift.max(boundedLimit * 4, 60)
        let semantic = try await vectorStore.search(query, embeddings, topK: internalLimit, filters: filters)

        var bm25: [String: Double] = [:]
        if let keyword = try await vectorStore.keywordSearch(queryLemmatized, topK: internalLimit, filters: filters) {
            let (midpoint, steepness) = Mem0Scoring.bm25Params(query, lemmatized: queryLemmatized)
            for mem in keyword where mem.score > 0 {
                bm25[mem.id] = Mem0Scoring.normalizeBM25(mem.score, midpoint: midpoint, steepness: steepness)
            }
        }

        let entityBoosts = queryEntities.isEmpty ? [:] : await computeEntityBoosts(queryEntities, filters)
        let scored = Mem0Scoring.scoreAndRank(semantic, bm25: bm25, entityBoosts: entityBoosts,
                                              threshold: threshold, topK: limit)

        var out: [JSONValue] = []
        for hit in scored {
            let hasData = (hit.payload["data"]?.stringValue.map { !$0.isEmpty }) ?? false
            if !hasData { continue }
            out.append(Self.formatMemoryItem(hit, excludeScore: false))
        }
        return out
    }

    // MARK: - entity linking (best-effort; requires an entity store)

    func linkEntities(_ records: [(id: String, text: String, vector: [Float], payload: JSONObject)],
                      _ searchFilters: JSONObject) async {
        guard let store = entityStore else { return }
        let texts = records.map { $0.text }
        let allEntities = Mem0NLP.extractEntitiesBatch(texts)

        var order: [String] = []
        var global: [String: (type: String, text: String, mids: Set<String>)] = [:]
        for (idx, rec) in records.enumerated() {
            guard idx < allEntities.count else { continue }
            for (etype, etext) in allEntities[idx] {
                let key = etext.trimmingCharacters(in: .whitespaces).lowercased()
                if key.isEmpty { continue }
                if global[key] != nil {
                    global[key]?.mids.insert(rec.id)
                } else {
                    order.append(key)
                    global[key] = (etype, etext, [rec.id])
                }
            }
        }
        if order.isEmpty { return }

        let entityTexts = order.map { global[$0]!.text }
        var embeddings: [[Float]?] = []
        if let vs = try? await embedder.embedBatch(entityTexts, .add), vs.count == entityTexts.count {
            embeddings = vs.map { Optional($0) }
        } else {
            for t in entityTexts { embeddings.append(try? await embedder.embed(t, .add)) }
        }

        var toInsert: [VectorRecord] = []
        for (i, key) in order.enumerated() {
            guard i < embeddings.count, let emb = embeddings[i] else { continue }
            let entry = global[key]!
            let matches = (try? await store.search(entry.text, emb, topK: 1, filters: searchFilters)) ?? []
            if let m = matches.first, m.score >= 0.95 {
                var payload = m.payload
                var linked = Set((payload["linked_memory_ids"]?.arrayValue ?? []).compactMap { $0.stringValue })
                for mid in entry.mids { linked.insert(mid) }
                payload["linked_memory_ids"] = .array(linked.sorted().map { .string($0) })
                try? await store.update(m.id, vector: nil, payload: payload)
                continue
            }
            var payload: JSONObject = [:]
            payload["data"] = .string(entry.text)
            payload["entity_type"] = .string(entry.type)
            payload["linked_memory_ids"] = .array(entry.mids.sorted().map { .string($0) })
            for (k, v) in searchFilters { payload[k] = v }
            toInsert.append(VectorRecord(id: UUID().uuidString, vector: emb, payload: payload))
        }
        if !toInsert.isEmpty { try? await store.insert(toInsert) }
    }

    func computeEntityBoosts(_ queryEntities: [(String, String)], _ filters: JSONObject) async -> [String: Double] {
        guard let store = entityStore else { return [:] }
        var seen = Set<String>()
        var deduped: [String] = []
        for (_, etext) in queryEntities.prefix(8) {
            let key = etext.trimmingCharacters(in: .whitespaces).lowercased()
            if !key.isEmpty && seen.insert(key).inserted { deduped.append(etext) }
        }
        if deduped.isEmpty { return [:] }

        let searchFilters = Mem0Filters.sessionFilters(filters)
        var boosts: [String: Double] = [:]
        for etext in deduped {
            guard let emb = try? await embedder.embed(etext, .search) else { continue }
            let matches = (try? await store.search(etext, emb, topK: 500, filters: searchFilters)) ?? []
            for m in matches where m.score >= 0.5 {
                let linked = (m.payload["linked_memory_ids"]?.arrayValue ?? []).compactMap { $0.stringValue }
                let numLinked = Double(max(linked.count, 1))
                let weight = 1.0 / (1.0 + 0.001 * pow(numLinked - 1.0, 2))
                let boost = m.score * Mem0Scoring.entityBoostWeight * weight
                for mid in linked {
                    if boost > (boosts[mid] ?? 0.0) { boosts[mid] = boost }
                }
            }
        }
        return boosts
    }

    // MARK: - mutations

    public func update(_ memoryID: String, data: String, metadata: JSONObject? = nil) async throws -> JSONValue {
        let embeddings = try await embedder.embed(data, .update)
        _ = try await updateMemory(memoryID, data: data, precomputed: embeddings, metadata: metadata)
        return .object(["message": .string("Memory updated successfully!")])
    }

    func updateMemory(_ memoryID: String, data: String, precomputed: [Float]?, metadata: JSONObject?) async throws -> String {
        guard let existing = try await vectorStore.get(memoryID) else {
            throw Mem0Error.notFound("Memory with id \(memoryID) not found")
        }
        let prevValue = existing.payload["data"]?.stringValue

        var newMetadata = metadata ?? [:]
        newMetadata["data"] = .string(data)
        newMetadata["hash"] = .string(md5Hex(data))
        newMetadata["text_lemmatized"] = .string(Mem0NLP.lemmatizeForBM25(data))
        let createdAt = existing.payload["created_at"] ?? .null
        newMetadata["created_at"] = createdAt
        let updatedAt = nowUTCRFC3339()
        newMetadata["updated_at"] = .string(updatedAt)

        for key in ["user_id", "agent_id", "run_id"] where newMetadata[key] == nil {
            if let v = existing.payload[key] { newMetadata[key] = v }
        }
        if let v = existing.payload["actor_id"] { newMetadata["actor_id"] = v }
        if newMetadata["role"] == nil, let v = existing.payload["role"] { newMetadata["role"] = v }

        let actorID = newMetadata["actor_id"]?.stringValue
        let role = newMetadata["role"]?.stringValue

        try await vectorStore.update(memoryID, vector: precomputed, payload: newMetadata)
        try await historyStore.addHistory(memoryID: memoryID, oldMemory: prevValue, newMemory: data,
                                          event: "UPDATE", createdAt: createdAt.stringValue,
                                          updatedAt: updatedAt, isDeleted: 0, actorID: actorID, role: role,
                                          userID: newMetadata["user_id"]?.stringValue,
                                          agentID: newMetadata["agent_id"]?.stringValue,
                                          runID: newMetadata["run_id"]?.stringValue)
        return memoryID
    }

    public func delete(_ memoryID: String) async throws -> JSONValue {
        guard let existing = try await vectorStore.get(memoryID) else {
            throw Mem0Error.notFound("Memory with id \(memoryID) not found")
        }
        _ = try await deleteMemory(memoryID, existing: existing)
        return .object(["message": .string("Memory deleted successfully!")])
    }

    func deleteMemory(_ memoryID: String, existing: SearchHit?) async throws -> String {
        let hit: SearchHit
        if let e = existing { hit = e } else {
            guard let e = try await vectorStore.get(memoryID) else {
                throw Mem0Error.notFound("Memory with id \(memoryID) not found")
            }
            hit = e
        }
        let prevValue = hit.payload["data"]?.stringValue ?? ""
        let createdAt = hit.payload["created_at"]?.stringValue
        let updatedAt = nowUTCRFC3339()
        let actorID = hit.payload["actor_id"]?.stringValue
        let role = hit.payload["role"]?.stringValue

        try await vectorStore.delete(memoryID)
        try await historyStore.addHistory(memoryID: memoryID, oldMemory: prevValue, newMemory: nil,
                                          event: "DELETE", createdAt: createdAt, updatedAt: updatedAt,
                                          isDeleted: 1, actorID: actorID, role: role,
                                          userID: hit.payload["user_id"]?.stringValue,
                                          agentID: hit.payload["agent_id"]?.stringValue,
                                          runID: hit.payload["run_id"]?.stringValue)
        return memoryID
    }

    public func deleteAll(userID: String? = nil, agentID: String? = nil, runID: String? = nil) async throws -> JSONValue {
        var filters: JSONObject = [:]
        if let v = userID { filters["user_id"] = .string(v) }
        if let v = agentID { filters["agent_id"] = .string(v) }
        if let v = runID { filters["run_id"] = .string(v) }
        if filters.isEmpty {
            throw Mem0Error.validationCode("VALIDATION_006",
                                           "At least one filter is required to delete all memories. Use reset() to delete everything.")
        }
        let hits = try await vectorStore.list(filters, limit: nil)
        for hit in hits { _ = try await deleteMemory(hit.id, existing: hit) }
        return .object(["message": .string("Memories deleted successfully!")])
    }

    public func history(_ memoryID: String) async throws -> [HistoryRecord] {
        try await historyStore.getHistory(memoryID)
    }

    public func reset() async throws {
        try await historyStore.reset()
        try await vectorStore.reset()
        if let store = entityStore { try? await store.reset() }
    }

    // MARK: - helpers

    /// Parse a `{"memory": [...]}` array, with `extractJSON` fallback.
    static func parseMemoryArray(_ cleaned: String) -> [JSONValue] {
        if let v = JSONValue.parse(cleaned), let arr = v.objectValue?["memory"]?.arrayValue {
            return arr
        }
        let ej = Mem0Text.extractJSON(cleaned)
        if let v = JSONValue.parse(ej), let arr = v.objectValue?["memory"]?.arrayValue {
            return arr
        }
        return []
    }

    /// Format a `SearchHit` into the public memory-item shape. Port of
    /// `format_memory_item`.
    static func formatMemoryItem(_ hit: SearchHit, excludeScore: Bool) -> JSONValue {
        let payload = hit.payload
        var item: JSONObject = [:]
        item["id"] = .string(hit.id)
        item["memory"] = payload["data"] ?? .string("")
        if let h = payload["hash"] { item["hash"] = h }
        if let c = payload["created_at"] { item["created_at"] = c }
        if let u = payload["updated_at"] { item["updated_at"] = u }
        if !excludeScore && hit.score != 0 { item["score"] = .double(hit.score) }

        for key in promotedKeys {
            if let v = payload[key] { item[key] = v }
        }

        let coreAndPromoted: Set<String> = [
            "data", "hash", "created_at", "updated_at", "id",
            "text_lemmatized", "attributed_to", "score",
            "user_id", "agent_id", "run_id", "actor_id", "role",
        ]
        var additional: JSONObject = [:]
        for (k, v) in payload where !coreAndPromoted.contains(k) { additional[k] = v }
        if !additional.isEmpty { item["metadata"] = .object(additional) }

        return .object(item)
    }
}
