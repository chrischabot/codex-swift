import Foundation
import InfraPrimitives
import MemoryStore
import MemoryInfer

/// Cost-aware admission control around expensive cloud calls (GPT-5.5, the
/// "BrainGate" of the design doc). Enforces a per-period USD ceiling, dedupes
/// near-simultaneous escalations on the same trigger via single-flight, and
/// records every spend event in the SQLite ledger.
public actor BrainGate {
    public struct Config: Sendable {
        public var monthlyCeilingUSD: Double
        public var bucket: String
        public var model: String
        public var fallbackModel: String
        public var modelInputUSDPerMTok: Double
        public var modelOutputUSDPerMTok: Double
        public var fallbackInputUSDPerMTok: Double
        public var fallbackOutputUSDPerMTok: Double

        public init(monthlyCeilingUSD: Double = 40,
                    bucket: String = "gpt55",
                    model: String = "gpt-5.5",
                    fallbackModel: String = "gpt-5.4-mini",
                    modelInputUSDPerMTok: Double = 5.00,
                    modelOutputUSDPerMTok: Double = 30.00,
                    fallbackInputUSDPerMTok: Double = 0.75,
                    fallbackOutputUSDPerMTok: Double = 4.50) {
            self.monthlyCeilingUSD = monthlyCeilingUSD
            self.bucket = bucket
            self.model = model
            self.fallbackModel = fallbackModel
            self.modelInputUSDPerMTok = modelInputUSDPerMTok
            self.modelOutputUSDPerMTok = modelOutputUSDPerMTok
            self.fallbackInputUSDPerMTok = fallbackInputUSDPerMTok
            self.fallbackOutputUSDPerMTok = fallbackOutputUSDPerMTok
        }
    }

    public enum Outcome: Sendable {
        case admitted(model: String, costEstimateUSD: Double)
        case rateLimited(reason: String)
        case duplicate(of: String)
        /// The caller returned, the model billed tokens (`costUSD` is the
        /// observed actual spend), but the response did not parse into a
        /// valid `InsightCard`. The gate refunds the budget — no spend row
        /// is written and no insight row is stored — and surfaces the raw
        /// text so the caller can log/triage it.
        case unparseable(model: String, observedCostUSD: Double, rawText: String)
    }

    public typealias Caller = @Sendable (_ prompt: String,
                                         _ model: String,
                                         _ deadline: Deadline)
                                         async throws -> (text: String,
                                                          tokensIn: Int,
                                                          tokensOut: Int)

    /// Internal pair of "parsed card outcome + realised cost" passed back
    /// through the single-flight task so `escalate` can refund vs. ledger
    /// without a second pass through the closure. Lifted out of `escalate`
    /// so `inFlight` can be properly typed (avoiding the prior bridge-Task
    /// that silently swallowed errors).
    fileprivate struct CallResult: Sendable {
        var card: InsightCard?
        var rawText: String
        var costUSD: Double
        var tokensIn: Int
        var tokensOut: Int
    }

    private let store: MemoryStore
    private let config: Config
    private let caller: Caller
    private var inFlight: [String: Task<CallResult, any Error>] = [:]

    public init(store: MemoryStore, config: Config = Config(), caller: @escaping Caller) {
        self.store = store
        self.config = config
        self.caller = caller
    }

    /// Try to escalate a trigger chunk. Returns nil if denied (rate-limit or
    /// duplicate); on admission produces the parsed `InsightCard` and records
    /// the spend.
    public func escalate(triggerChunkId: Int64,
                         dedupeKey: String,
                         prompt: String,
                         summaryOnly: Bool,
                         score: Double,
                         deadline: Deadline) async throws -> Outcome {
        // 1. Rate-limit on the monthly ceiling. Bucket spend is recorded after
        //    the actual call so this check is conservative — pessimistically
        //    assume the maximum the configured caps could spend.
        let monthStart = Self.monthStart(now: Int64(Date().timeIntervalSince1970))
        let alreadySpent = try await store.monthlySpend(bucket: config.bucket,
                                                       monthStart: monthStart)
        if alreadySpent >= config.monthlyCeilingUSD {
            return .rateLimited(reason: "monthly ceiling reached: spent \(alreadySpent) / cap \(config.monthlyCeilingUSD)")
        }
        // 2. Single-flight: collapse concurrent escalations on the same key.
        if let existing = inFlight[dedupeKey] {
            _ = try? await existing.value
            return .duplicate(of: dedupeKey)
        }
        let model = summaryOnly ? config.fallbackModel : config.model
        let inPerM = summaryOnly ? config.fallbackInputUSDPerMTok : config.modelInputUSDPerMTok
        let outPerM = summaryOnly ? config.fallbackOutputUSDPerMTok : config.modelOutputUSDPerMTok

        // Pair the parsed-card outcome with the realised cost so the gate
        // can ledger only on success and refund silently on unparseable
        // output (the design doc's documented contract). `CallResult` lives
        // at type scope so `inFlight` can store it directly without a
        // bridging Task that would swallow errors.
        let task: Task<CallResult, any Error> = Task {
            let result = try await caller(prompt, model, deadline)
            let cost = Double(result.tokensIn) / 1_000_000 * inPerM
                     + Double(result.tokensOut) / 1_000_000 * outPerM
            // Parse FIRST. Only record spend + insight + metrics if the
            // response yields a valid card; on unparseable output the model
            // billed tokens but the gate refunds the budget so subsequent
            // calls aren't starved by malformed responses.
            guard let data = result.text.data(using: .utf8),
                  let card = try? JSONDecoder().decode(InsightCard.self, from: data)
            else {
                return CallResult(card: nil, rawText: result.text, costUSD: cost,
                                  tokensIn: result.tokensIn, tokensOut: result.tokensOut)
            }
            let now = Int64(Date().timeIntervalSince1970)
            try await store.recordSpend(SpendRow(
                ts: now, bucket: config.bucket,
                units: Double(result.tokensIn + result.tokensOut),
                unitKind: "tokens", costUSD: cost))
            MemoryMetrics.brainCall(model: model,
                                    tokensIn: result.tokensIn,
                                    tokensOut: result.tokensOut,
                                    costUSD: cost)
            try await store.insertInsight(InsightRow(
                triggerChunkId: triggerChunkId,
                model: model,
                inputTokens: Int64(result.tokensIn),
                outputTokens: Int64(result.tokensOut),
                cachedInputTokens: 0,
                costUSD: cost,
                score: score,
                cardMD: result.text,
                createdAt: now))
            return CallResult(card: card, rawText: result.text, costUSD: cost,
                              tokensIn: result.tokensIn, tokensOut: result.tokensOut)
        }
        inFlight[dedupeKey] = task
        defer { inFlight.removeValue(forKey: dedupeKey) }
        let result = try await task.value
        if result.card == nil {
            return .unparseable(model: model,
                                observedCostUSD: result.costUSD,
                                rawText: result.rawText)
        }
        let estimate = inPerM * Double(result.tokensIn) / 1_000_000
                     + outPerM * Double(result.tokensOut) / 1_000_000
        return .admitted(model: model, costEstimateUSD: estimate)
    }

    /// Compute the start-of-month UNIX timestamp for the spend window check.
    static func monthStart(now: Int64) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: TimeInterval(now))
        let components = calendar.dateComponents([.year, .month], from: date)
        let monthDate = calendar.date(from: components) ?? date
        return Int64(monthDate.timeIntervalSince1970)
    }
}
