import Foundation

/// Embedded built-in workflow scripts. `deep-research` is always registered;
/// the five remote-gated built-ins are registered only when
/// `CODEX_WORKFLOWS_REMOTE` is truthy (port of the `CLAUDE_CODE_REMOTE` gate).
public enum BuiltinWorkflows {
    public static func all(env: [String: String] = ProcessInfo.processInfo.environment) -> [WorkflowDef] {
        var defs: [WorkflowDef] = [deepResearch]
        if WorkflowGating.remoteBuiltinsEnabled(env: env) {
            defs.append(investigate)
            defs.append(contentsOf: RemoteBuiltinWorkflows.all.map(make))
        }
        return defs
    }

    static func make(_ script: String) -> WorkflowDef {
        // Parse the embedded meta so phases/description stay single-sourced.
        if let meta = try? WorkflowMeta.parse(script) {
            return WorkflowDef(source: .builtIn, name: meta.name, description: meta.description,
                               whenToUse: meta.whenToUse, phases: meta.phases, script: script)
        }
        return WorkflowDef(source: .builtIn, name: "unknown", description: "", script: script)
    }

    // GPT-translated deep-research. Tool names swapped to codex
    // (`web_search`/`web_fetch`); Claude's `pipeline(angles,…)` is expressed as
    // a `parallel` fan-out so stage chains run concurrently under the pump.
    public static let deepResearch = make(#"""
    export const meta = {
      name: "deep-research",
      description: "Deep research harness — fan-out web searches, fetch sources, adversarially verify claims, synthesize a cited report.",
      whenToUse: "When the user wants a deep, multi-source, fact-checked research report. If the question is underspecified, ask 2-3 clarifying questions first, then pass the refined question as args.",
      phases: [
        { title: "Scope",      detail: "Decompose the question (from args) into search angles" },
        { title: "Search",     detail: "Parallel web_search agents, one per angle" },
        { title: "Verify",     detail: "Adversarial verification per claim (majority refute to kill)" },
        { title: "Synthesize", detail: "Rank by confidence and cite sources" }
      ]
    };

    const QUESTION = typeof args === "string" ? args : (args && args.question) || String(args || "");
    const VOTES_PER_CLAIM = 3;
    const REFUTATIONS_REQUIRED = 2;

    const SCOPE_SCHEMA = {
      type: "object", additionalProperties: false,
      required: ["angles"],
      properties: { angles: { type: "array", items: { type: "string" }, minItems: 3, maxItems: 6 } }
    };
    const SEARCH_SCHEMA = {
      type: "object", additionalProperties: false,
      required: ["claims", "sources"],
      properties: {
        claims: { type: "array", items: { type: "object", additionalProperties: false,
          required: ["text", "source"], properties: { text: { type: "string" }, source: { type: "string" } } } },
        sources: { type: "array", items: { type: "string" } }
      }
    };
    const VERDICT_SCHEMA = {
      type: "object", additionalProperties: false,
      required: ["refuted", "reason"],
      properties: { refuted: { type: "boolean" }, reason: { type: "string" } }
    };

    phase("Scope");
    const scope = await agent(
      "Decompose this research question into 3-6 distinct search angles. " +
      "Return ONLY the angles.\n\nQuestion: " + QUESTION,
      { label: "scope", schema: SCOPE_SCHEMA });
    const angles = (scope && scope.angles) || [QUESTION];

    phase("Search");
    const searches = await parallel(angles.map(function(angle){
      return function(){
        return agent(
          "Research this angle of the question using the web_search and web_fetch tools. " +
          "Extract concrete, falsifiable claims, each with the source URL it came from.\n\n" +
          "Overall question: " + QUESTION + "\nAngle: " + angle,
          { label: "search: " + angle, schema: SEARCH_SCHEMA });
      };
    }));

    const claims = [];
    const sources = [];
    searches.filter(Boolean).forEach(function(s){
      (s.claims || []).forEach(function(c){ claims.push(c); });
      (s.sources || []).forEach(function(u){ if (sources.indexOf(u) < 0) sources.push(u); });
    });

    phase("Verify");
    const verified = await parallel(claims.map(function(claim){
      return function(){
        return parallel(Array.from({ length: VOTES_PER_CLAIM }, function(_, i){
          return function(){
            return agent(
              "Try to REFUTE this claim using web_search/web_fetch. Default to refuted=true if you " +
              "cannot find supporting evidence. (verifier " + (i + 1) + " of " + VOTES_PER_CLAIM + ")\n\n" +
              "Claim: " + claim.text + "\nClaimed source: " + claim.source,
              { label: "verify", schema: VERDICT_SCHEMA });
          };
        })).then(function(votes){
          var refutes = votes.filter(Boolean).filter(function(v){ return v.refuted; }).length;
          return { claim: claim, real: refutes < REFUTATIONS_REQUIRED };
        });
      };
    }));

    const confirmed = verified.filter(Boolean).filter(function(v){ return v.real; }).map(function(v){ return v.claim; });
    const refuted = verified.filter(Boolean).filter(function(v){ return !v.real; }).map(function(v){ return v.claim; });

    phase("Synthesize");
    const report = await agent(
      "Write a concise, well-structured research report answering the question, citing the " +
      "confirmed claims and their sources. Note any important caveats.\n\n" +
      "Question: " + QUESTION + "\n\nConfirmed claims:\n" +
      JSON.stringify(confirmed, null, 2) + "\n\nSources:\n" + JSON.stringify(sources, null, 2),
      { label: "synthesize" });

    return {
      question: QUESTION,
      report: report,
      confirmed: confirmed,
      refuted: refuted,
      sources: sources,
      stats: { angles: angles.length, claims: claims.length, confirmed: confirmed.length, refuted: refuted.length }
    };
    """#)

    // Report-only investigate (no PR side effects) — cheapest remote built-in
    // to port. Uses the local shell/read tools the subagents already have.
    public static let investigate = make(#"""
    export const meta = {
      name: "investigate",
      description: "Investigate a question about this codebase across multiple angles and synthesize findings (report only, no edits).",
      whenToUse: "When the user wants a thorough, multi-angle investigation of the codebase without making changes.",
      phases: [
        { title: "Decompose", detail: "Break the question into investigation angles" },
        { title: "Investigate", detail: "Parallel read-only investigators" },
        { title: "Synthesize", detail: "Merge findings into a report" }
      ]
    };

    const Q = typeof args === "string" ? args : (args && args.question) || String(args || "");
    const ANGLES_SCHEMA = { type: "object", additionalProperties: false, required: ["angles"],
      properties: { angles: { type: "array", items: { type: "string" }, minItems: 2, maxItems: 6 } } };

    phase("Decompose");
    const d = await agent("Break this codebase investigation into 2-6 angles. Return only the angles.\n\n" + Q,
      { label: "decompose", schema: ANGLES_SCHEMA });
    const angles = (d && d.angles) || [Q];

    phase("Investigate");
    const findings = await parallel(angles.map(function(a){
      return function(){
        return agent("Investigate this angle of the question using read-only tools (read_file, file_search, shell for grep). " +
          "Report concrete findings with file:line references.\n\nQuestion: " + Q + "\nAngle: " + a,
          { label: "investigate: " + a });
      };
    }));

    phase("Synthesize");
    const report = await agent("Synthesize these investigation findings into a clear report answering the question.\n\n" +
      "Question: " + Q + "\n\nFindings:\n" + JSON.stringify(findings.filter(Boolean), null, 2),
      { label: "synthesize" });

    return { question: Q, report: report, angles: angles };
    """#)
}
