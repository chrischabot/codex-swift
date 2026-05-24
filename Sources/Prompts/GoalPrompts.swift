import Foundation

/// Faithful port of the prompt/accounting helpers in
/// `codex-rs/core/src/goals.rs`.
public enum GoalPrompts {

    public enum Kind: Sendable, Equatable { case continuation, budgetLimit, objectiveUpdated }

    /// `escape_xml_text` — `&` first, then `<`, then `>`.
    public static func escapeXmlText(_ input: String) -> String {
        input.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Renders the goal steering prompt body (pre-`<goal_context>` wrap),
    /// matching `continuation_prompt` / `budget_limit_prompt` /
    /// `objective_updated_prompt`.
    public static func prompt(kind: Kind,
                              objective: String,
                              tokensUsed: Int64,
                              tokenBudget: Int64?,
                              timeUsedSeconds: Int64) -> String {
        let tokenBudgetStr = tokenBudget.map(String.init) ?? "none"
        let remaining = tokenBudget
            .map { String(Swift.max(0, $0 - tokensUsed)) } ?? "unbounded"
        let esc = escapeXmlText(objective)
        let r = TemplateRenderer()
        switch kind {
        case .continuation:
            return r.render(Templates.goalContinuation, [
                "objective": esc,
                "tokens_used": String(tokensUsed),
                "token_budget": tokenBudgetStr,
                "remaining_tokens": remaining,
            ])
        case .budgetLimit:
            return r.render(Templates.goalBudgetLimit, [
                "objective": esc,
                "tokens_used": String(tokensUsed),
                "time_used_seconds": String(timeUsedSeconds),
                "token_budget": tokenBudgetStr,
            ])
        case .objectiveUpdated:
            return r.render(Templates.goalObjectiveUpdated, [
                "objective": esc,
                "tokens_used": String(tokensUsed),
                "token_budget": tokenBudgetStr,
                "remaining_tokens": remaining,
            ])
        }
    }

    /// `goal_context_input_item` — wrap the rendered prompt in a hidden
    /// `<goal_context>` user fragment. Returns `(role, renderedText)`.
    public static func goalContextItem(kind: Kind,
                                       objective: String,
                                       tokensUsed: Int64,
                                       tokenBudget: Int64?,
                                       timeUsedSeconds: Int64) -> (role: String, text: String) {
        let p = prompt(kind: kind, objective: objective, tokensUsed: tokensUsed,
                       tokenBudget: tokenBudget, timeUsedSeconds: timeUsedSeconds)
        return GoalContext(prompt: p).roleAndText()
    }

    /// `goal_token_delta_for_usage` = non_cached_input + max(0, output).
    public static func goalTokenDelta(inputTokens: Int64, cachedInputTokens: Int64,
                                      outputTokens: Int64) -> Int64 {
        let nonCached = Swift.max(0, inputTokens - cachedInputTokens)
        return nonCached + Swift.max(0, outputTokens)
    }
}