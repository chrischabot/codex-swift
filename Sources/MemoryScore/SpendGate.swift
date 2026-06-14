import Foundation
import InfraPrimitives
import MemoryStore

/// Generic cost-aware admission control around any expensive (cloud/frontier)
/// model call. Generalizes `BrainGate`'s monthly-ceiling + token-cost + SQLite
/// spend-ledger logic, decoupled from `InsightCard`/`triggerChunkId`, so the
/// research / audit / compile / output frontier calls can all flow through one
/// shared budget. `BrainGate` keeps its own InsightCard-specific
/// refund-on-unparseable behavior; this is the gate for everything else.
public actor SpendGate {
    public struct Config: Sendable, Equatable {
        public var monthlyCeilingUSD: Double
        public var bucket: String
        public var inputUSDPerMTok: Double
        public var outputUSDPerMTok: Double
        public init(monthlyCeilingUSD: Double = 40, bucket: String = "wiki-frontier",
                    inputUSDPerMTok: Double = 5.0, outputUSDPerMTok: Double = 30.0) {
            self.monthlyCeilingUSD = monthlyCeilingUSD; self.bucket = bucket
            self.inputUSDPerMTok = inputUSDPerMTok; self.outputUSDPerMTok = outputUSDPerMTok
        }
    }

    public struct Receipt: Sendable, Equatable {
        public var text: String
        public var tokensIn: Int
        public var tokensOut: Int
        public var costUSD: Double
        public init(text: String, tokensIn: Int, tokensOut: Int, costUSD: Double) {
            self.text = text; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.costUSD = costUSD
        }
    }

    public enum Outcome: Sendable {
        case ran(Receipt)
        case rateLimited(reason: String, spentUSD: Double, ceilingUSD: Double)

        public var receipt: Receipt? { if case .ran(let r) = self { return r }; return nil }
        public var isRateLimited: Bool { if case .rateLimited = self { return true }; return false }
    }

    public typealias TokenCall = @Sendable (_ prompt: String, _ model: String, _ deadline: Deadline)
        async throws -> (text: String, tokensIn: Int, tokensOut: Int)

    private let store: MemoryStore
    private let config: Config

    public init(store: MemoryStore, config: Config = Config()) {
        self.store = store; self.config = config
    }

    /// Run `call` iff under the monthly ceiling, then record token spend + emit the
    /// brain-call metric. Returns `.rateLimited` WITHOUT calling when the budget is
    /// exhausted. The ceiling check is conservative (spend is recorded after the
    /// call), so concurrent calls may briefly overshoot by one call — the ceiling
    /// is a soft budget, not a hard wallet.
    public func run(prompt: String, model: String, deadline: Deadline = .distantFuture,
                    _ call: TokenCall) async throws -> Outcome {
        let monthStart = BrainGate.monthStart(now: Int64(Date().timeIntervalSince1970))
        let spent = try await store.monthlySpend(bucket: config.bucket, monthStart: monthStart)
        if spent >= config.monthlyCeilingUSD {
            return .rateLimited(reason: "monthly ceiling reached", spentUSD: spent, ceilingUSD: config.monthlyCeilingUSD)
        }
        let r = try await call(prompt, model, deadline)
        let cost = Double(r.tokensIn) / 1_000_000 * config.inputUSDPerMTok
                 + Double(r.tokensOut) / 1_000_000 * config.outputUSDPerMTok
        let now = Int64(Date().timeIntervalSince1970)
        try await store.recordSpend(SpendRow(ts: now, bucket: config.bucket,
                                             units: Double(r.tokensIn + r.tokensOut),
                                             unitKind: "tokens", costUSD: cost))
        MemoryMetrics.brainCall(model: model, tokensIn: r.tokensIn, tokensOut: r.tokensOut, costUSD: cost)
        return .ran(Receipt(text: r.text, tokensIn: r.tokensIn, tokensOut: r.tokensOut, costUSD: cost))
    }

    /// Month-to-date spend for this gate's bucket (status/UI).
    public func monthlySpentUSD() async throws -> Double {
        try await store.monthlySpend(bucket: config.bucket,
                                     monthStart: BrainGate.monthStart(now: Int64(Date().timeIntervalSince1970)))
    }

    public func remainingBudgetUSD() async throws -> Double {
        max(0, config.monthlyCeilingUSD - (try await monthlySpentUSD()))
    }
}
